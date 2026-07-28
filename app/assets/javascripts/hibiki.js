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

  async connect() {
    this.aborted = false
    consumer ??= createConsumer()
    this.defineForwarders()
    // Turbo-broadcast transport: wait for the element's own stream source
    // to confirm before subscribing, so the graph's dependency-collecting
    // first run broadcasts into a live stream. No source (transmit
    // transport) → this path is fully synchronous, exactly as before.
    const source = this.streamSource()
    if (source) await streamConnected(source)
    if (this.aborted) return // disconnected during the await
    this.subscription = consumer.subscriptions.create(
      this.subscribeParams(),
      { received: (data) => this.received(data) }
    )
  }

  // What identifies this subscription to the server. Override to add
  // params; keep channel/cid, which the Ruby side requires.
  subscribeParams() {
    return { channel: this.channelName(), cid: this.cidValue }
  }

  disconnect() {
    this.aborted = true
    this.subscription?.unsubscribe()
    this.subscription = undefined
  }

  // DOM → server: what declared action methods call. Optional chaining
  // because a debounced action can fire after disconnect, and a sentinel
  // can fire while connect is still awaiting its stream source.
  perform(action, payload = {}) {
    this.subscription?.perform(action, payload)
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
        this.scanSentinels()
      }
    }
    document.addEventListener("turbo:before-stream-render", this.streamRender)

    await super.connect()
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
    this.perform(action, payload)
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
