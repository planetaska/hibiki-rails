// The packaged client for hibiki_rails. Two shapes, one plumbing:
//
// 1. The generic controller (HibikiController, register as "hibiki"):
//    drives any island stamped by the Hibiki::Rails::Helpers Ruby
//    helpers. Stimulus is the lifecycle host only (connect/disconnect
//    across Turbo navigation, morphs, and dynamic insertion); the wire
//    protocol is hibiki-owned data attributes, so server-side components
//    never write Stimulus vocabulary and a non-Stimulus client can speak
//    the same attributes (toy-phlex's vanilla driver is the proof).
// 2. The subclassable base (ChannelController): for apps that prefer the
//    familiar Stimulus structure (data-controller="counter",
//    data-action="counter#increment"). The base owns the consumer, the
//    subscription lifecycle, and transport handling; plain actions are
//    auto-forwarded to the channel, so a subclass only declares a method
//    when it needs something custom:
//
//      import { ChannelController } from "hibiki-rails"
//
//      // identifier "counter" infers CounterChannel (override with
//      // `static channel = "..."` when the names don't line up)
//      export default class extends ChannelController {
//        setStep(event) {
//          this.perform("set_step", { step: event.target.value })
//        }
//      }
//
// Both shapes speak both transports. Transmit: the server's render
// effects `transmit({ html: })` fragments that are swapped in by their
// root DOM id, and `transmit_value` messages that update every
// data-hibiki-value placeholder; `received` is registered at subscribe
// time — before the
// server runs build_graph — so the effects' first transmits always land
// (the server-rendered initial HTML is only a paint-avoidance
// placeholder). Turbo broadcasts: when the controller's element contains
// its own <turbo-cable-stream-source> (turbo_stream_from), the graph's
// first broadcast is lost unless that stream has already confirmed ITS
// subscription — so connect awaits it (streamConnected) before
// subscribing, and rendering flows back over the Turbo stream while
// `received` stays idle.
//
// The attribute contract of the generic controller (private to this gem —
// emitted by the Ruby helpers, interpreted here, versioned together):
//
//   island root   data-controller="hibiki"
//                 data-hibiki-channel-value="CounterChannel"
//                 data-hibiki-cid-value="<per-page-load id>"
//                 data-hibiki-params-value='{"record_id":7}'  extra subscribe
//                 params, merged UNDER channel/cid so they can't override them
//   controls      data-hibiki-on="<event>-><action> ..."  whitespace-separated;
//                 e.g. "click->load_more visible->load_more"
//                 data-hibiki-with='{"index":3}'       optional JSON payload
//                 data-hibiki-debounce="250"           ms to let the gesture settle
//                 data-hibiki-confirm="Are you sure?"  window.confirm gate
//                 data-hibiki-reset="false"            keep a submitted form's inputs
//   value sites   data-hibiki-value="<name>"           reactive-value placeholder;
//                 the server's transmit_value message updates every match
//
// The protocol also has a client-written half — the first attributes in it
// that no Ruby helper emits. These are stamped here at runtime and are
// read-only to app code; app CSS is their whole audience:
//
//   island root   data-hibiki-busy       present while an action is in flight
//                 aria-busy="true"       the same fact, for assistive tech
//                 data-hibiki-state      connecting | ready | offline | stalled
//   firing control data-hibiki-busy      on the control that started it
//
// Everything the app wants out of that is a descendant selector —
// `[data-hibiki-busy] .spinner { display: inline-block }` — so per-row and
// per-button feedback needs no server state and no `{#if loading}` branch.
// Content is stale during a round trip, never absent.
//
// The left side of `->` is a hibiki event name, of which DOM events are a
// subset: click, change, input, submit are delegated listeners, and
// `visible` is a pseudo-event backed by an IntersectionObserver (the
// element entering the viewport). Everything that is not "which event"
// is a sibling attribute, so the token grammar never has to grow.
//
// Register the generic controller under the identifier "hibiki" (the
// helpers hardcode it):
//
//   import HibikiController from "hibiki-rails"
//   application.register("hibiki", HibikiController)
import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// One consumer shared by every controller — ActionCable multiplexes
// subscriptions over a single websocket. Never disconnected: islands come
// and go with the DOM, the socket stays.
let consumer

// camelCase Stimulus method name → snake_case Ruby channel action.
const underscore = (name) => name.replace(/([A-Z])/g, "_$1").toLowerCase()

// What a changed control contributes to its action's payload. A checkbox's
// `value` is its value ATTRIBUTE, not its state, so reading `value` made
// checking and unchecking send byte-identical payloads; a multi-select's
// `value` is only its first selected option. A radio needs no special case:
// `change` fires on the newly-checked input, so `value` is already right.
const controlValue = (control) => {
  if (control.type === "checkbox") return control.checked
  if (control.multiple && control.selectedOptions) {
    return [...control.selectedOptions].map((option) => option.value)
  }
  return control.value
}

// The subclassable base: one channel subscription per controller element,
// identified by a per-page-load cid (data-<identifier>-cid-value).
export class ChannelController extends Controller {
  static values = { cid: String }

  // Transport-state timings. Class properties on purpose: not Stimulus
  // values and not helper options, so the Ruby surface stays unchanged and
  // an island stamps nothing about them. An app that wants different
  // numbers subclasses and re-registers.
  //
  // busyDelay   ms before a round trip is worth mentioning. A localhost
  //             trip measures 18–25 ms, so 150 suppresses that flicker
  //             outright while a 150 ms-RTT link crosses it about exactly.
  //             Borrowed from Turbo's progress bar, which waits ~500 ms.
  // busyGrace   ms to wait after an ack for a Turbo render still in
  //             flight. The ack travels the island's own socket; a
  //             broadcast takes a pubsub hop, and measured against
  //             generated output the direct frame beats the paint by
  //             3.3–3.6 ms. That gap belongs to the server and its
  //             backend, so it does not shrink on a fast link — and Redis
  //             widens it. Hence a bound in tens of ms, not single digits.
  // busyCeiling ms before a trip is declared stalled rather than silently
  //             cleared. On a bad link "we lost it" beats "nothing
  //             happened".
  static busyDelay = 150
  static busyGrace = 60
  static busyCeiling = 10000

  async connect() {
    this.prepareTransport()
    await this.openSubscription()
  }

  // The synchronous half of connect: everything a listener firing in the
  // next millisecond depends on. HibikiController attaches its delegated
  // listeners before openSubscription is even called, and the window
  // before the subscription confirms is ~3 serialised round trips on the
  // Turbo-broadcast path (Turbo's own subscribe, a SECOND websocket
  // handshake, then ours) — tens of ms on localhost, about a second on a
  // real remote link. Clicks in it used to vanish without a trace.
  prepareTransport() {
    this.aborted = false
    this.subscribed = false
    this.connectedOnce = false
    this.seq = 0
    this.renders = 0
    this.busy = new Map()
    this.queued = []
    this.setState("connecting")
  }

  async openSubscription() {
    consumer ??= createConsumer()
    this.defineForwarders()
    // Turbo-broadcast transport: wait for the element's own stream source
    // to confirm before subscribing, so the graph's dependency-collecting
    // first run broadcasts into a live stream. No source (transmit
    // transport) → this path is fully synchronous, exactly as before.
    const source = this.streamSource()
    if (source) await streamConnected(source)
    if (this.aborted) return // disconnected during the await
    this.subscription = consumer.subscriptions.create(this.subscribeParams(), {
      received: (data) => this.handleMessage(data),
      connected: () => this.linkOpened(),
      disconnected: () => this.linkClosed()
    })
  }

  // What identifies this subscription to the server. Override to add
  // params; keep channel/cid, which the Ruby side requires.
  subscribeParams() {
    return { channel: this.channelName(), cid: this.cidValue }
  }

  disconnect() {
    this.aborted = true
    this.settleAll()
    this.subscription?.unsubscribe()
    this.subscription = undefined
    this.subscribed = false
    this.queued = []
  }

  // DOM → server: what declared action methods call. Every perform carries
  // a sequence number under the reserved `hbk` key and opens a busy record
  // that the matching ack closes; the seq is stamped LAST so a form field
  // can never overwrite it. (`hbk` is the second reserved payload key —
  // ActionCable's own Subscription#perform already writes `action`.)
  //
  // Returns the seq so a caller that knows which control fired can attach
  // it; nobody has to.
  perform(action, payload = {}) {
    const seq = ++this.seq
    payload.hbk = seq
    if (this.subscribed) {
      this.beginBusy(seq)
      this.subscription.perform(action, payload)
      return seq
    }
    // Queue rather than drop while the subscription is still coming up.
    // ActionCable's Subscription#perform silently returns false on a socket
    // that is not open yet, so this was a silent no-op for the whole
    // connect window — and the trigger has to be the `connected` callback,
    // not "the subscription object exists", because the second websocket's
    // handshake sits between the two.
    //
    // Only that first window. Once the link has been up, a gap means the
    // socket dropped, and reconnecting builds a FRESH graph server-side
    // with default state — so replaying intent formed against the old one
    // is worse than dropping it. The island is stamped `offline` for the
    // whole gap, which is the signal the connect window cannot give: there
    // the page is painted and looks live.
    if (!this.connectedOnce) {
      this.beginBusy(seq)
      this.queued.push([action, payload])
    }
    return seq
  }

  // ActionCable's `connected`, i.e. the server confirmed the subscription.
  // Fires again after every reconnect.
  linkOpened() {
    this.subscribed = true
    this.connectedOnce = true
    this.setState("ready")
    const queued = this.queued
    this.queued = []
    for (const [action, payload] of queued) this.subscription.perform(action, payload)
  }

  linkClosed() {
    this.subscribed = false
    this.setState("offline")
    // Deliberately NOT queued across the gap. A reconnect builds a fresh
    // graph server-side with default state, so replaying intent formed
    // against the old one is worse than dropping it. Outstanding records
    // settle for the same reason: their acks are never coming.
    this.queued = []
    this.settleAll()
  }

  setState(state) {
    this.state = state
    this.element.setAttribute("data-hibiki-state", state)
  }

  // ── The busy machine ──────────────────────────────────────────────────
  //
  // A depth counter, not a boolean: typing while a page loads is one island
  // with two actions outstanding. No requestAnimationFrame anywhere — it
  // never fires in a background tab, which is exactly when a stuck
  // indicator goes unnoticed.

  beginBusy(seq) {
    const record = {
      control: null,
      // Which render the island was on when this started, so the ack can
      // ask "has anything painted since?" without consulting a clock.
      renders: this.renders,
      ceiling: setTimeout(() => this.stall(seq), this.constructor.busyCeiling)
    }
    this.busy.set(seq, record)
    // Start the show-delay on 0→1 only: a second overlapping action must
    // not restart it, because the user has been waiting since the first.
    if (this.busy.size === 1) {
      this.showTimer = setTimeout(() => this.showBusy(), this.constructor.busyDelay)
    }
    return record
  }

  // Attach the control that started a trip, so it can carry its own flag.
  // Controls inside a server-replaced fragment are cleared by the swap
  // itself (an idiomorph repaint syncs attributes, and the incoming HTML
  // has none); controls outside it — the search field — need the removal
  // in settle().
  trackControl(seq, control) {
    const record = this.busy.get(seq)
    if (!record) return
    record.control = control
    if (this.busyShown) control.setAttribute("data-hibiki-busy", "")
  }

  showBusy() {
    this.showTimer = undefined
    this.busyShown = true
    this.element.setAttribute("data-hibiki-busy", "")
    this.element.setAttribute("aria-busy", "true")
    for (const record of this.busy.values()) {
      record.control?.setAttribute("data-hibiki-busy", "")
    }
  }

  // The clear rule, and the whole design: a `dropped` ack settles at once
  // because nothing is coming; a normal ack settles at once if a render has
  // already landed, and otherwise waits out the grace window for one still
  // in flight, then settles regardless — an action that legitimately
  // rendered nothing is the ordinary case the ack exists for.
  acknowledge({ ack, dropped }) {
    // Any ack proves the link is alive again.
    if (this.state === "stalled") this.setState("ready")
    const record = this.busy.get(ack)
    if (!record) return
    if (dropped || this.renders > record.renders) return this.settle(ack)
    record.grace = setTimeout(() => this.settle(ack), this.constructor.busyGrace)
  }

  settle(seq) {
    const record = this.busy.get(seq)
    if (!record) return
    clearTimeout(record.ceiling)
    clearTimeout(record.grace)
    this.busy.delete(seq)
    record.control?.removeAttribute("data-hibiki-busy")
    if (this.busy.size === 0) this.hideBusy()
  }

  settleAll() {
    for (const seq of [...this.busy.keys()]) this.settle(seq)
    this.hideBusy() // an already-empty map still has a show timer to cancel
  }

  hideBusy() {
    clearTimeout(this.showTimer)
    this.showTimer = undefined
    this.busyShown = false
    this.element.removeAttribute("data-hibiki-busy")
    this.element.removeAttribute("aria-busy")
  }

  // Say so rather than clearing silently: on a bad link the honest report
  // is "we lost it", and a cleared indicator claims the opposite.
  stall(seq) {
    this.settle(seq)
    this.setState("stalled")
  }

  // Every inbound frame lands here first. Acks are transport bookkeeping,
  // handled by the base and deliberately NOT routed through received() — so
  // a subclass that overrides received without calling super still clears
  // its pending state.
  handleMessage(data) {
    if (data && "ack" in data) return this.acknowledge(data)
    if (data && data.html) this.renders++
    this.received(data)
  }

  // Server → DOM (transmit transport). Two message shapes:
  //
  // { value: { name, text } } — a reactive value (transmit_value): write
  // the text into every [data-hibiki-value=name] placeholder, document-
  // wide (a value may render outside its island; names are page-unique).
  // textContent assignment keeps values text-only and preserves each
  // site's own tag/classes, so per-placeholder styling survives updates.
  //
  // { html } — a fragment: swap it in by its root id.
  //
  // Anything else is not ours to interpret. Subclasses may override, but
  // should call super (or handle `value`) to keep reactive values live.
  received({ html, value }) {
    if (value) {
      const selector = `[data-hibiki-value="${CSS.escape(value.name)}"]`
      for (const site of document.querySelectorAll(selector)) {
        site.textContent = value.text
      }
      return
    }
    if (!html) return
    const template = document.createElement("template")
    template.innerHTML = html
    for (const fragment of [...template.content.children]) {
      document.getElementById(fragment.id)?.replaceWith(fragment)
    }
  }

  // `static channel = "..."` wins; otherwise infer Rails-style from the
  // identifier: "counter" → CounterChannel, "my-thing" → MyThingChannel.
  channelName() {
    if (this.constructor.channel) return this.constructor.channel
    const pascal = this.identifier
      .split(/[-_]/)
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join("")
    return `${pascal}Channel`
  }

  // Auto-forwarding: every data-action token addressed to this identifier
  // whose method the subclass did NOT declare gets a generated forwarder
  // that performs the underscored action with no payload — so plain
  // forwards need zero code. Declared methods always win. Methods are
  // defined at connect: action NAMES first appearing in later-inserted
  // markup aren't discovered (names already seen keep working anywhere,
  // Stimulus binds the elements itself).
  defineForwarders() {
    for (const control of this.element.querySelectorAll("[data-action]")) {
      for (const token of control.dataset.action.trim().split(/\s+/)) {
        const method = this.forwardableMethod(token)
        if (method && typeof this[method] !== "function") {
          this[method] = () => this.perform(underscore(method))
        }
      }
    }
  }

  // Token forms: "identifier#method", "event->identifier#method", plus
  // trailing :options — returns the method name, or null when the token
  // addresses another controller.
  forwardableMethod(token) {
    const descriptor = token.includes("->") ? token.split("->")[1] : token
    const [identifier, method] = descriptor.split("#")
    if (identifier !== this.identifier || !method) return null
    return method.split(":")[0]
  }

  // The element's own <turbo-cable-stream-source>, if any. Scoped like
  // forward() below: a nested controller's source belongs to IT.
  streamSource() {
    return [...this.element.querySelectorAll("turbo-cable-stream-source")].find(
      (s) => s.closest(`[data-controller~="${this.identifier}"]`) === this.element
    )
  }
}

// The generic controller: adds the data-hibiki-* wire protocol on top of
// the base's plumbing.
export default class HibikiController extends ChannelController {
  // cid inherited from the base. `params` defaults to {} when the island
  // stamps no data-hibiki-params-value.
  static values = { channel: String, params: Object }

  // The island stamps its channel; no inference.
  channelName() {
    return this.channelValue
  }

  // Extra subscribe params go UNDER channel/cid: they are client-supplied,
  // so a page must not be able to point its subscription at another channel
  // or steal another tab's graph by naming its cid. The server-side rule
  // that goes with this is in Helpers#hibiki_island.
  subscribeParams() {
    return { ...this.paramsValue, ...super.subscribeParams() }
  }

  async connect() {
    // Before the listeners, not after: a click delegated in the next
    // millisecond reaches perform(), which needs the busy map and the
    // queue to exist. This is also what stamps data-hibiki-state
    // ="connecting" synchronously, so the island can be dimmed for the
    // whole window rather than from the middle of it.
    this.prepareTransport()

    // Root-scoped delegation (bound to the island, not document): controls
    // inside server-replaced fragments keep working with no rebinding.
    // Set up synchronously so disconnect can always tear them down.
    this.listeners = ["click", "change", "input", "submit"].map((type) => {
      const handler = (event) => this.forward(event)
      this.element.addEventListener(type, handler)
      return [type, handler]
    })

    // Debounce bookkeeping: a WeakMap keyed by control (so detached
    // elements don't pin memory) plus a flat set of live timeouts, which is
    // what disconnect can actually iterate.
    this.timers = new WeakMap()
    this.pending = new Set()

    // `visible` is not a DOM event, so it needs its own observer beside the
    // delegated listeners. Always on, never a pluggable module: an
    // IntersectionObserver watching zero elements costs nothing at runtime,
    // while an optional import brings back the failure mode where the
    // attribute is present, the code isn't, and nothing errors.
    this.observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        // Fire once per observation. The re-scan after the next swap
        // observes the REPLACEMENT element, and its fresh initial callback
        // is what stops the classic "the new page didn't fill the viewport,
        // so the loop stalls" trap.
        this.observer.unobserve(entry.target)
        this.dispatch(entry.target, { type: "visible", target: entry.target })
      }
    })

    // Re-scan at the two points a fragment can be swapped under us, rather
    // than blanket-observing the document: a MutationObserver over the page
    // is a real per-mutation cost paid by every app on it.
    this.streamRender = (event) => {
      const render = event.detail.render
      event.detail.render = async (streamElement) => {
        await render(streamElement)
        // The Turbo transport's paint. Counting it here is what lets an ack
        // settle immediately instead of waiting out its grace window. The
        // listener is on the document, so an unrelated broadcast counts too
        // — which at worst settles an already-acked trip a few ms early,
        // never one that has not been acked at all.
        this.renders++
        this.scanSentinels()
      }
    }
    document.addEventListener("turbo:before-stream-render", this.streamRender)

    await this.openSubscription()
    if (this.aborted) return
    this.scanSentinels()
  }

  disconnect() {
    for (const [type, handler] of this.listeners) {
      this.element.removeEventListener(type, handler)
    }
    document.removeEventListener("turbo:before-stream-render", this.streamRender)
    for (const id of this.pending) clearTimeout(id)
    this.pending.clear()
    this.observer.disconnect()
    super.disconnect()
  }

  // The other swap point: hibiki's own transmit transport.
  received(data) {
    super.received(data)
    if (data.html) this.scanSentinels()
  }

  // Observe every `visible->` sentinel this island owns. observe() is a
  // no-op for an element already being observed, so re-scanning is cheap
  // and cannot double-fire a sentinel that merely stayed put.
  scanSentinels() {
    for (const control of this.element.querySelectorAll('[data-hibiki-on*="visible->"]')) {
      if (control.closest('[data-controller~="hibiki"]') === this.element) {
        this.observer.observe(control)
      }
    }
  }

  // DOM → server: forward a control's event as a channel action.
  forward(event) {
    const control = event.target.closest("[data-hibiki-on]")
    if (control) this.dispatch(control, event)
  }

  // The shared path for both sources of events — the delegated DOM
  // listeners and the visibility observer.
  dispatch(control, event) {
    // Nested islands: events bubble to every ancestor island's listener, so
    // each controller only acts when the control belongs to ITS island.
    if (control.closest('[data-controller~="hibiki"]') !== this.element) return

    const token = control.dataset.hibikiOn
      .split(/\s+/)
      .find((t) => t.startsWith(`${event.type}->`))
    if (!token) return
    const action = token.slice(event.type.length + 2)

    // Before the confirm, not after: declining must not let the form
    // navigate away.
    if (event.type === "submit") event.preventDefault()

    const message = control.dataset.hibikiConfirm
    if (message && !window.confirm(message)) return

    // The payload is built when the action actually fires, so a debounced
    // input sends what the user finished typing rather than the first
    // keystroke that started the timer.
    const wait = Number(control.dataset.hibikiDebounce)
    const fire = () => this.send(control, event, action)
    if (wait > 0) this.debounce(control, action, wait, fire)
    else fire()
  }

  send(control, event, action) {
    const payload = control.dataset.hibikiWith
      ? JSON.parse(control.dataset.hibikiWith)
      : {}
    if (event.type === "submit") {
      Object.assign(payload, Object.fromEntries(new FormData(control)))
    } else if (control.name && (event.type === "change" || event.type === "input")) {
      payload[control.name] = controlValue(control)
    }
    // perform stamps `hbk` after this merge, so a field literally named hbk
    // loses to the seq rather than corrupting it.
    this.trackControl(this.perform(action, payload), control)
    // Resetting is right for an "add" form and wrong for an edit one: it
    // runs synchronously, before the server has replied, so a failed commit
    // would discard what the user typed.
    if (event.type === "submit" && control.dataset.hibikiReset !== "false") {
      control.reset()
    }
  }

  // One timer per (control, action): two events on one element debounce
  // independently, and a second control's typing never cancels the first's.
  debounce(control, action, wait, fire) {
    let byAction = this.timers.get(control)
    if (!byAction) {
      byAction = new Map()
      this.timers.set(control, byAction)
    }
    const previous = byAction.get(action)
    if (previous) {
      clearTimeout(previous)
      this.pending.delete(previous)
    }
    const id = setTimeout(() => {
      byAction.delete(action)
      this.pending.delete(id)
      fire()
    }, wait)
    byAction.set(action, id)
    this.pending.add(id)
  }
}

export { HibikiController }

// The Turbo-broadcast race helper the base uses internally, still
// exported for custom (non-Stimulus) clients: resolves once Turbo stamps
// the `connected` attribute on the given <turbo-cable-stream-source>.
export function streamConnected(element) {
  if (element.hasAttribute("connected")) return Promise.resolve()

  return new Promise((resolve) => {
    const observer = new MutationObserver(() => {
      if (element.hasAttribute("connected")) {
        observer.disconnect()
        resolve()
      }
    })
    observer.observe(element, { attributeFilter: ["connected"] })
  })
}
