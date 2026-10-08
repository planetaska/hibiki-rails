// The packaged client for hibiki_rails. Two shapes, one plumbing:
//
// 1. The generic controller (HibikiController, registered as "hibiki"):
//    drives any island stamped by the Hibiki::Rails::Helpers Ruby
//    helpers. Stimulus is only the lifecycle host (connect/disconnect
//    across Turbo navigation, morphs, and dynamic insertion); the wire
//    protocol is hibiki-owned data attributes, so server-side components
//    never write Stimulus vocabulary.
// 2. The subclassable base (ChannelController): for apps that prefer
//    familiar Stimulus structure (data-controller="counter",
//    data-action="counter#increment"). The base owns the consumer, the
//    subscription lifecycle, and transport handling. Plain actions are
//    auto-forwarded to the channel; a subclass declares a method only
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
// data-hibiki-value placeholder. `received` is registered at subscribe
// time, before the server runs build_graph, so the effects' first
// transmits always land; the server-rendered HTML fills the space only
// until they do. Turbo broadcasts: when the controller's element
// contains its own <turbo-cable-stream-source> (turbo_stream_from), the
// graph's first broadcast is lost unless that stream has already
// confirmed ITS subscription — so connect awaits it (streamConnected)
// before subscribing, and rendering flows back over the Turbo stream
// while `received` stays idle.
//
// The generic controller's attribute contract (private to this gem —
// emitted by the Ruby helpers, interpreted here, versioned together):
//
//   island root   data-controller="hibiki"
//                 data-hibiki-channel-value="CounterChannel"
//                 data-hibiki-cid-value="<per-page-load id>"
//                 data-hibiki-params-value='{"record_id":7}'  extra subscribe
//                 params, merged UNDER channel/cid so they can't override them
//   controls      data-hibiki-on="<event>-><action> ..."  whitespace-separated;
//                 e.g. "click->load_more visible->load_more". A key is
//                 "keydown.<key>" (heard inside the control) or
//                 "keydown.<key>@window" (heard anywhere), with ctrl+ meta+
//                 shift+ in front in that order; only the names in KEYS below
//                 data-hibiki-with='{"index":3}'       optional JSON payload
//                 data-hibiki-debounce="250"           ms to let the gesture settle
//                 data-hibiki-confirm="Are you sure?"  window.confirm gate
//                 data-hibiki-reset="false"            keep a submitted form's inputs
//                 data-hibiki-fallback="true"          the control's native behavior
//                 (a link's navigation, a form's action=) is its fallback: while the
//                 island is `ready` the event is intercepted and only the channel
//                 action fires; in every other state the client stands aside and the
//                 browser does what the markup says
//   value sites   data-hibiki-value="<name>"           reactive-value placeholder;
//                 the server's transmit_value message updates every match
//   prop sites    data-hibiki-props='{"indeterminate":true}'  DOM properties
//                 that have no attribute, assigned on connect and after each
//                 render; only the names in PROPS below, an optional "key"
//                 beside them existing to change the text
//   focus sites   data-hibiki-focus="true|select"      takes focus, and has its
//                 text selected, when a render this tab caused inserts it
//
// The client writes the protocol's other half at runtime — read-only to
// app code, addressed to app CSS:
//
//   island root   data-hibiki-busy       present while an action is in flight
//                 aria-busy="true"       the same fact, for assistive tech
//                 data-hibiki-state      connecting | ready | offline | stalled
//   firing control data-hibiki-busy      on the control that started it
//
// App CSS reaches all of it with descendant selectors —
// `[data-hibiki-busy] .spinner { display: inline-block }` — so per-row
// and per-button feedback needs no server state. Content is stale during
// a round trip, never absent.
//
// Motion is the one PUBLIC data-* contract, and it lives in the opt-in
// module `hibiki-rails/motion`: an app marks an element `data-motion` (or
// `data-motion="own"`), the module stamps `data-motion-leaving` /
// `data-motion-entering` around a swap and holds the render while a
// leaving element's transitions run. Its header carries the rules; this
// file only gives it two seams — `islandFor` and the `hibiki:before-render`
// event the transmit swap dispatches (the same shape Turbo gives streams).
//
// The left side of `->` is a hibiki event name: click, change, input,
// and submit are delegated DOM listeners; `visible` is a pseudo-event
// backed by an IntersectionObserver (the element entering the viewport).
// Everything that is not "which event" is a sibling attribute, so the
// token grammar never has to grow.
//
// A debounced field holds text the server has not heard, and two rules keep
// it. A render landing inside the wait is drawn without the text, so the
// client records it at input time and puts it back after the render: a
// field with unsent input wins, until its send fires. And any undebounced
// action first flushes the island's pending debounces, so gestures reach
// the server in the order they were made.
//
// A focus site takes focus once, on the render that brings it: marked now
// and not at the scan before, by element or by id. Only a render this tab
// caused counts, one that arrived while an action was in flight or just
// after its ack, so a render nobody here asked for never moves the cursor.
// A mark in the page's first HTML is `autofocus`'s business, and a refresh
// morph focuses nothing.
//
// Focus is also given back. When a render removes the element that had
// focus, it would fall to <body>: a keyboard user loses their place, and
// the island stops hearing keys. So the client looks, in order, for the
// element now carrying the same id (a replaced field); for the control
// whose gesture opened the focus site that render closed (the Edit button
// of a form now gone), known again after a re-render by its id or by its
// action and payload; and for the first control of the focused element's
// nearest id-bearing ancestor. Only controls: when none of these is there,
// focus is left where the browser put it. Any render, whoever caused it.
//
// App JS reaching the graph — the ONE public seam. A gesture that needs
// script (drag-and-drop, a third-party widget) fires its action through
// the island's OWN subscription: `perform(action, payload)` on the island
// controller instance is public API. Reach the instance with Stimulus's
// standard lookup —
//
//   const islandEl = element.closest('[data-controller~="hibiki"]')
//   const island = application.getControllerForElementAndIdentifier(islandEl, "hibiki")
//   island?.perform("nested_move", { path, to })
//
// — or skip the incantation with the performOn export at the bottom of
// this file (works outside Stimulus too):
//
//   import { performOn } from "hibiki-rails"
//   performOn(element, "nested_move", { path, to })
//
// The return value is the whole contract. Truthy (the trip's seq): the
// action was ACCEPTED — sent live, or queued during the initial connect
// window — a repaint is coming, so leave the DOM as the user arranged it
// and let the morph land as a visual no-op. Falsy (undefined): it was
// DROPPED — the island is offline, or the socket was dead at send — and
// the caller owns recovery: revert the gesture, or let the next repaint
// self-heal. Nothing queues across an offline gap, on purpose: a
// reconnect builds a fresh server-side graph, so replayed intent would
// land on state it was not formed against. Everything else is NOT a
// seam: the data-hibiki-* attributes are private, and subclassing
// ChannelController to reach an existing island opens a SECOND
// subscription — a second server-side graph nobody paints from.
//
// Register the generic controller under the identifier "hibiki" (the
// helpers hardcode it):
//
//   import HibikiController from "hibiki-rails"
//   application.register("hibiki", HibikiController)
import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// One consumer shared by every controller — and with Turbo Streams: it is
// turbo-rails' own (`cable.getConsumer()`), so islands and
// `turbo_stream_from` multiplex over ONE websocket, and an app's
// `cable.setConsumer(...)` applies to both. Never disconnected: islands
// come and go with the DOM, the socket stays. Importing turbo-rails'
// consumer rather than @rails/actioncable also keeps the library out of
// the page twice (turbo-rails bundles it by a subpath specifier that no
// importmap can serve).
let consumer

// Live islands by root element, for performOn's ancestor walk — membership
// here, not an attribute probe, so the helper couples to neither the
// identifier string nor the wire attributes. Generic islands only:
// ChannelController subclasses have `this.perform`. WeakMap so a removed
// island pins nothing even if disconnect never ran.
const islands = new WeakMap()

// The generic island CONTAINING element, or undefined. The walk performOn
// uses, exported for the motion module's `own` policy — which reads the
// island's trip records, so a ChannelController subclass (not in the map)
// yields no records: its `own` marks never animate a leave a Turbo stream
// removes. (The transmit swap's event carries the subclass itself, so
// `own` works there once the subclass tracks its controls.)
export function islandFor(element) {
  for (let node = element; node; node = node.parentElement) {
    const island = islands.get(node)
    if (island) return island
  }
  return undefined
}

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

// A trailing [] is a serialization artifact, not part of the attribute name:
// the channel payload is JSON, where arrays are native.
const payloadKey = (name) => (name.endsWith("[]") ? name.slice(0, -2) : name)

// A submitted form's contribution to the payload. A []-named field collects
// EVERY entry as an array under the bare key; other duplicate keys stay
// last-wins, which is what lets Rails' hidden-field checkbox convention
// submit "1" when checked and "0" when not.
const formPayload = (form) => {
  const data = new FormData(form)
  const payload = {}
  for (const key of new Set(data.keys())) {
    const all = data.getAll(key)
    payload[payloadKey(key)] = key.endsWith("[]") ? all : all.at(-1)
  }
  return payload
}

// Before a fallback form goes native, re-stamp its CSRF token from the
// page's csrf-token meta tag, which is first-paint fresh and
// session-valid. Server-side repaints render without a session
// (ApplicationController.render has none), so a repainted form embeds a
// stale token or none at all. This only runs with scripts alive —
// exactly when the DOM may have been repainted; a script-free page
// still holds its first-paint token.
const freshenToken = (control) => {
  if (!(control instanceof HTMLFormElement)) return
  const meta = document.querySelector('meta[name="csrf-token"]')
  if (!meta) return
  let input = control.querySelector('input[name="authenticity_token"]')
  if (!input) {
    input = document.createElement("input")
    input.type = "hidden"
    input.name = "authenticity_token"
    control.appendChild(input)
  }
  input.value = meta.content
}

// The subclassable base: one channel subscription per controller element,
// identified by a per-page-load cid (data-<identifier>-cid-value).
export class ChannelController extends Controller {
  static values = { cid: String }

  // Transport-state timings. Class properties on purpose: not Stimulus
  // values and not helper options, so the Ruby surface stays unchanged
  // and an island stamps nothing about them. An app that wants different
  // numbers subclasses and re-registers.
  //
  // busyDelay   ms before a round trip is worth mentioning — long enough
  //             to swallow a localhost trip (18–25 ms) without flicker.
  // busyGrace   ms to wait after an ack for a Turbo render still in
  //             flight. The ack rides the island's own socket while the
  //             broadcast takes a pubsub hop, so the ack routinely wins
  //             by a few ms — a gap owned by the server's backend, which
  //             no fast link shrinks. Hence tens of ms, not single digits.
  // busyCeiling ms before a trip is declared stalled rather than silently
  //             cleared. On a bad link "we lost it" beats "nothing
  //             happened".
  // focusGrace  ms after a trip settles in which a render still counts as
  //             its answer (see own()). One action can broadcast twice: the
  //             first render settles the trip with the ack and the second
  //             trails both. Longer than busyGrace because a missed focus
  //             costs more than a spinner's flicker.
  static busyDelay = 150
  static busyGrace = 60
  static busyCeiling = 10000
  static focusGrace = 500

  async connect() {
    this.prepareTransport()
    await this.openSubscription()
  }

  // The synchronous half of connect: everything a listener firing in the
  // next millisecond depends on. HibikiController attaches its delegated
  // listeners before openSubscription is even called, and on the
  // Turbo-broadcast path the subscription takes ~3 serialised round
  // trips to confirm — up to a second on a real link. Clicks in that
  // window used to vanish without a trace.
  prepareTransport() {
    this.aborted = false
    this.subscribed = false
    this.connectedOnce = false
    this.seq = 0
    this.renders = 0
    this.busy = new Map()
    this.settledAt = -Infinity
    this.lastControl = null
    this.queued = []
    this.setState("connecting")
  }

  async openSubscription() {
    this.defineForwarders()
    // Turbo-broadcast transport: wait for the element's own stream source
    // to confirm before subscribing, so the graph's dependency-collecting
    // first run broadcasts into a live stream. No source (transmit
    // transport) → only the consumer await below, a microtask once it
    // exists (turbo-rails memoizes it).
    const source = this.streamSource()
    if (source) await streamConnected(source)
    consumer ??= await cable.getConsumer()
    if (this.aborted) return // disconnected during the awaits
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
  // Public API on the island controller (the header's "App JS reaching
  // the graph"). Returns the seq when the action was accepted, so a
  // caller that knows which control fired can attach it; returns
  // undefined when the payload went nowhere — the socket turned out to
  // be closed, or the island was already offline — and the caller owns
  // recovery.
  perform(action, payload = {}) {
    const seq = ++this.seq
    payload.hbk = seq
    if (this.subscribed) {
      this.beginBusy(seq)
      // Subscription#perform returns false when the socket is not open —
      // the gap between the socket dying and the connection monitor
      // noticing, during which `subscribed` still says live. The frame
      // went nowhere: settle the trip rather than let it stall out at
      // the ceiling, and stamp `offline` now instead of when the monitor
      // catches up. The monitor still owns reconnecting.
      if (this.subscription.perform(action, payload) === false) {
        this.settle(seq)
        this.linkClosed()
        return undefined
      }
      return seq
    }
    // Queue rather than drop while the subscription is still coming up:
    // Subscription#perform silently returns false on a socket not open
    // yet, so the whole connect window used to be a silent no-op. The
    // gate must be the `connected` callback, not "the subscription
    // object exists" — the second websocket's handshake sits between
    // the two.
    //
    // Only that first window. Once the link has been up, a gap means
    // the socket dropped, and the island is stamped `offline` for the
    // whole gap — the signal the connect window cannot give, where the
    // page is painted and looks live.
    if (!this.connectedOnce) {
      this.beginBusy(seq)
      this.queued.push([action, payload])
      return seq
    }
    // The offline gap: dropped, and the return says so — a truthy seq here
    // would tell a public caller a repaint is coming when none is.
    return undefined
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
    // Deliberately NOT queued across the gap: a reconnect builds a fresh
    // graph server-side, so replayed intent would land on state it was
    // not formed against. Outstanding records settle for the same
    // reason — their acks are never coming.
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
  // indicator goes unnoticed. (The motion module is the one place a frame
  // is waited for, and it waits for nothing in a hidden document.) An ack
  // settles a trip even while that module is holding the render: the flag
  // means the server has not answered, and a hold is motion after the
  // answer.

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
    // The most recent gesture, kept past its trip's settle for the motion
    // module's `own` policy (a render can land after the ack's grace). Set
    // before the record check: a send that died on the socket was still a
    // gesture. A ChannelController subclass wanting `own` calls this itself —
    // which serves the transmit swap only: a Turbo stream reaches the
    // records through islandFor, and that walk lists generic islands alone.
    this.lastControl = control
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
    this.settledAt = performance.now()
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

  // Whether a render arriving now answers this tab's own action: one is in
  // flight, or settled within the grace. Asked when the render arrives, not
  // when it is applied, since the motion module may hold it for a second.
  own() {
    return this.busy.size > 0 || performance.now() - this.settledAt <= this.constructor.focusGrace
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

  // Server → DOM (transmit transport). Three message shapes:
  //
  // { value: { name, text } } — a reactive value (transmit_value): write
  // the text into every [data-hibiki-value=name] placeholder, document-
  // wide (a value may render outside its island; names are page-unique).
  // textContent assignment keeps values text-only and preserves each
  // site's own tag/classes, so per-placeholder styling survives updates.
  //
  // { url } — mirror graph state into the address bar (transmit_url).
  //
  // { html } — a fragment: swap it in by its root id. The swap is holdable
  // the way Turbo's is: `hibiki:before-render` bubbles from the island
  // first (detail { island, content, render }), and a listener may replace
  // detail.render with one that waits — the motion module does, to let a
  // leaving element's transition finish. Returns whatever that render
  // returns: undefined when the swap ran synchronously, a promise when it
  // was held, which is what a subclass reading the DOM afterwards awaits.
  //
  // Anything else is not ours to interpret. Subclasses may override, but
  // should call super (or handle `value`) to keep reactive values live.
  received({ html, value, url }) {
    if (value) {
      const selector = `[data-hibiki-value="${CSS.escape(value.name)}"]`
      for (const site of document.querySelectorAll(selector)) {
        site.textContent = value.text
      }
      return
    }
    if (url !== undefined) return this.replaceUrl(url)
    if (!html) return
    const template = document.createElement("template")
    template.innerHTML = html
    const fragments = [...template.content.children]
    const render = () => {
      for (const fragment of fragments) {
        document.getElementById(fragment.id)?.replaceWith(fragment)
      }
    }
    const event = new CustomEvent("hibiki:before-render", {
      bubbles: true,
      detail: { island: this, content: template.content, render }
    })
    this.element.dispatchEvent(event)
    return event.detail.render()
  }

  // replaceState, never pushState: the URL is a mirror of graph state, not
  // a history entry — Back needs no popstate handling and leaves the page
  // normally. Same-origin only, so a channel can move the bar solely
  // within its own app (replaceState would throw on a cross-origin URL;
  // refusing keeps it silent and intentional).
  replaceUrl(url) {
    const resolved = new URL(url, window.location.href)
    if (resolved.origin !== window.location.origin) return
    history.replaceState(history.state, "", resolved)
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
  // forwards need zero code. Declared methods always win. Forwarders are
  // defined at connect, so an action NAME first appearing in
  // later-inserted markup isn't discovered; a name already seen keeps
  // working anywhere, because Stimulus binds the elements itself.
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

// The DOM properties a fragment may set (Helpers#props), and when. A
// property has no attribute, so no swap or morph carries it: the client
// assigns it after the fact. The table is the allowlist — a fragment must
// never reach innerHTML or onclick — and a value of the wrong type is
// skipped. `always` is re-assigned after every render (the browser clears
// indeterminate on click; the server's value comes back). `changed` is
// assigned only to a new element or when the attribute's text differs from
// the text last applied, so the visitor's own scrolling survives unrelated
// renders; the view's `key:` is how it says "again".
const PROPS = {
  indeterminate: ["boolean", "always"],
  scrollTop: ["number", "changed"],
  scrollLeft: ["number", "changed"]
}
const appliedProps = new WeakMap()

// Fields whose state is not their `value`, so there is no typed text to keep.
const typed = (field) =>
  typeof field.value === "string" &&
  !field.multiple &&
  !["checkbox", "radio", "file"].includes(field.type)

// The keys a `keydown.<key>` token may name, by the `event.key` each
// reports; a single letter or digit names itself. The server keeps the same
// list (Keys in the gem) and emits nothing outside it.
const KEYS = {
  enter: "Enter",
  tab: "Tab",
  esc: "Escape",
  space: " ",
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
  home: "Home",
  end: "End",
  page_up: "PageUp",
  page_down: "PageDown"
}
const KEYED = '[data-hibiki-on*="keydown."]'
const HOTKEYED = '[data-hibiki-on*="@window"]'
const ISLAND = '[data-controller~="hibiki"]'

// A key press that is a gesture: not part of an IME composition (Safari
// reports the Enter that ends one only as keyCode 229), not a held key's
// repeat, and not Chrome's keyless autofill event.
const heard = (event) =>
  typeof event.key === "string" &&
  !event.isComposing &&
  event.keyCode !== 229 &&
  !event.repeat

// Where a plain key is text, or moves within it.
const NOT_TEXT = new Set([
  "checkbox", "radio", "file", "button", "submit", "reset", "image", "range", "color"
])
const entering = (target) =>
  !!target.closest?.('textarea, select, [contenteditable]:not([contenteditable="false"])') ||
  (target.localName === "input" && !NOT_TEXT.has(target.type))

// The action of the control's first key token of this scope ("" or
// "window") that the event matches. Modifiers match exactly, and Alt
// matches nothing: on macOS it changes the character the key reports.
// `typing` is a window key pressed in a text field, where only Escape and
// ctrl or meta combinations are not the field's own.
function keyAction(control, event, scope, typing = false) {
  const pressed = event.key.length === 1 ? event.key.toLowerCase() : event.key
  for (const token of (control.dataset.hibikiOn ?? "").split(/\s+/)) {
    if (!token.startsWith("keydown.")) continue
    const [bound, action] = token.slice(8).split("->")
    const [combo, at = ""] = bound.split("@")
    if (at !== scope) continue
    const modifiers = combo.split("+")
    const name = modifiers.pop()
    if ((KEYS[name] ?? (name.length === 1 ? name : null)) !== pressed) continue
    const ctrl = modifiers.includes("ctrl")
    const meta = modifiers.includes("meta")
    if (typing && !ctrl && !meta && name !== "esc") continue
    if (
      event.ctrlKey === ctrl &&
      event.metaKey === meta &&
      event.shiftKey === modifiers.includes("shift") &&
      !event.altKey
    ) {
      return action
    }
  }
}

// What focus return may land on inside a surviving ancestor.
const FOCUSABLE =
  'a[href], button:not(:disabled), input:not(:disabled):not([type="hidden"]), ' +
  'select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])'

// Key events a window binding answered, so a second island declaring the
// same key still fires where a key taken by anything else is left alone.
const hotkeyed = new WeakSet()

function applyProps(element) {
  const text = element.getAttribute("data-hibiki-props")
  let wanted
  try {
    wanted = JSON.parse(text)
  } catch {
    return
  }
  if (!wanted || typeof wanted !== "object") return
  const fresh = appliedProps.get(element) !== text
  for (const [name, [type, policy]] of Object.entries(PROPS)) {
    const value = wanted[name]
    if (typeof value !== type || (type === "number" && !Number.isFinite(value))) continue
    if (policy === "always" || fresh) element[name] = value
  }
  appliedProps.set(element, text)
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
    islands.set(this.element, this)
    // Before the listeners, not after: a click delegated in the next
    // millisecond reaches perform(), which needs the busy map and the
    // queue to exist. This also stamps data-hibiki-state="connecting"
    // synchronously, so the island can be dimmed for the whole window
    // rather than from the middle of it.
    this.prepareTransport()

    // First paint, so before the subscription: a property is right while
    // the island is still connecting, and stays right if it never does.
    for (const site of this.element.querySelectorAll("[data-hibiki-props]")) {
      applyProps(site)
    }

    // Root-scoped delegation (bound to the island, not document): controls
    // inside server-replaced fragments keep working with no rebinding.
    // Set up synchronously so disconnect can always tear them down.
    this.listeners = ["click", "change", "input", "submit"].map((type) => {
      const handler = (event) => this.forward(event)
      this.element.addEventListener(type, handler)
      return [type, handler]
    })
    // Keys take their own path: a key names its control by a token, not by
    // being the nearest one.
    const keydown = (event) => this.key(event)
    this.element.addEventListener("keydown", keydown)
    this.listeners.push(["keydown", keydown])
    // On the window only while the island has a window key; see scan().
    this.hotkeys = (event) => this.hotkey(event)

    // Debounce bookkeeping: a WeakMap keyed by control (so detached
    // elements don't pin memory) plus the live timeouts with what each
    // will run, which is what disconnect and flush can actually iterate.
    // `unsent` is the text those timeouts have yet to send, by field.
    this.timers = new WeakMap()
    this.pending = new Map()
    this.unsent = new Map()
    // The focus sites seen at the last scan, each with the control whose
    // gesture opened it, when one did; a site not among them is new.
    // Seeded now, so a render landing in the connect window finds the
    // page's own marks already seen.
    this.marks = new Map()
    for (const site of this.element.querySelectorAll("[data-hibiki-focus]")) {
      if (site.closest(ISLAND) === this.element) this.marks.set(site, undefined)
    }

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

    // Re-scan at the points a fragment can be swapped under us, rather
    // than blanket-observing the document: a MutationObserver over the page
    // is a real per-mutation cost paid by every app on it.
    this.streamRender = (event) => {
      const render = event.detail.render
      const arrival = this.arrival()
      event.detail.render = async (streamElement) => {
        await render(streamElement)
        // The Turbo transport's paint. Counting it here is what lets an ack
        // settle immediately instead of waiting out its grace window. The
        // listener is on the document, so an unrelated broadcast counts too
        // — which at worst settles an already-acked trip a few ms early,
        // never one that has not been acked at all.
        this.renders++
        this.scan(arrival)
      }
    }
    document.addEventListener("turbo:before-stream-render", this.streamRender)
    // A refresh stream morphs the page after its own render has returned,
    // so the wrapper above scans too early for it; turbo:render follows
    // the morph.
    // It is nobody's own render, so it brings no focus, but it can
    // take the focused element away like any other.
    this.pageBefore = () => {
      this.paging = { trail: this.trail() }
    }
    this.pageRender = () => {
      this.scan(this.paging)
      this.paging = undefined
    }
    document.addEventListener("turbo:before-render", this.pageBefore)
    document.addEventListener("turbo:render", this.pageRender)

    await this.openSubscription()
    if (this.aborted) return
    this.scan()
  }

  disconnect() {
    islands.delete(this.element)
    for (const [type, handler] of this.listeners) {
      this.element.removeEventListener(type, handler)
    }
    document.removeEventListener("turbo:before-stream-render", this.streamRender)
    document.removeEventListener("turbo:before-render", this.pageBefore)
    document.removeEventListener("turbo:render", this.pageRender)
    window.removeEventListener("keydown", this.hotkeys)
    for (const id of this.pending.keys()) clearTimeout(id)
    this.pending.clear()
    this.unsent.clear()
    this.marks.clear()
    this.observer.disconnect()
    super.disconnect()
  }

  // The other swap point: hibiki's own transmit transport. A held swap
  // hands back a promise; the replacement sentinel exists only after it.
  received(data) {
    const arrival = this.arrival()
    const swapped = super.received(data)
    if (!data.html) return
    if (swapped?.then) swapped.then(() => this.scan(arrival))
    else this.scan(arrival)
  }

  // What is only knowable as a render arrives: whether it answers this
  // tab's action, the control that action came from (the motion module
  // forgets it once a held render lands), and where focus was.
  arrival() {
    return { own: this.own(), control: this.lastControl, trail: this.trail() }
  }

  // The focused element, when it is this island's, with the ids from it
  // upward, nearest first, and its caret.
  trail() {
    const element = document.activeElement
    if (!element || element === this.element || element.closest?.(ISLAND) !== this.element) return
    const ids = []
    for (let node = element; node !== this.element; node = node.parentElement) {
      if (node.id) ids.push(node.id)
    }
    if (this.element.id) ids.push(this.element.id)
    return { element, ids, self: Boolean(element.id), start: element.selectionStart, end: element.selectionEnd }
  }

  // Give focus back after a render removed the element that had it; the
  // header has the rule. `opener` is the control behind a focus site the
  // same render closed. Left alone when focus has gone somewhere since.
  refocus({ element, ids, self, start, end }, opener) {
    if (element.isConnected) return
    const active = document.activeElement
    if ((active && active !== document.body && active.isConnected) || !this.element.isConnected) return
    const found = (id) => {
      const survivor = document.getElementById(id)
      return survivor && this.element.contains(survivor) ? survivor : null
    }
    const index = ids.findIndex(found)
    if (self && index === 0) {
      const twin = found(ids[0])
      twin.focus()
      if (start != null && document.activeElement === twin) twin.setSelectionRange?.(start, end)
      return
    }
    const candidates = [opener && this.twin(opener)]
    if (index === (self ? 1 : 0)) candidates.push(...found(ids[index]).querySelectorAll(FOCUSABLE))
    for (const control of candidates) {
      control?.focus()
      if (control && document.activeElement === control) return
    }
  }

  // The control a gesture came from, or the one a render has put in its
  // place: the same id, else the same action and payload.
  twin({ element, id, on, payload }) {
    if (element.isConnected) return element
    const twin = id
      ? document.getElementById(id)
      : [...this.element.querySelectorAll("[data-hibiki-on]")].find(
          (control) => control.dataset.hibikiOn === on && control.dataset.hibikiWith === payload
        )
    return twin?.closest(ISLAND) === this.element ? twin : null
  }

  // What a render leaves for the client to finish: put back unsent text,
  // then in one walk of the island assign every prop site's properties,
  // observe every `visible->` sentinel this island owns, listen on the
  // window while a window key is declared, and settle focus: on the first
  // focus site the render brought when it was this tab's `own`, else back
  // to a control when the render removed the focused element. Focus before
  // the unsent text, whose caret goes only to the focused field. observe()
  // is a no-op for an element already being observed, so re-scanning is
  // cheap and cannot double-fire a sentinel that merely stayed put; adding
  // a listener twice is a no-op too. Props need no ownership check: assigning one twice,
  // from a nested island and its parent, lands the same value. Nor does
  // the window listener, which finds nothing of its own to fire.
  scan({ own = false, control, trail } = {}) {
    const found = this.element.querySelectorAll(
      `[data-hibiki-on*="visible->"], [data-hibiki-props], [data-hibiki-focus], ${HOTKEYED}`
    )
    let hotkeys = this.element.matches(HOTKEYED)
    // A site is the one seen before when it is that element or, after a
    // replace, carries its id; it keeps the opener either way.
    const seen = new Map()
    for (const [was, opener] of this.marks) if (was.id) seen.set(was.id, opener)
    const marks = new Map()
    const ids = new Set()
    let site
    for (const element of found) {
      if (element.hasAttribute("data-hibiki-focus") && element.closest(ISLAND) === this.element) {
        marks.set(element, this.marks.get(element) ?? seen.get(element.id))
        if (element.id) ids.add(element.id)
        if (!this.marks.has(element) && !seen.has(element.id)) site ??= element
      }
      hotkeys ||= element.dataset.hibikiOn?.includes("@window")
      if (element.hasAttribute("data-hibiki-props")) applyProps(element)
      if (
        element.dataset.hibikiOn?.includes("visible->") &&
        element.closest('[data-controller~="hibiki"]') === this.element
      ) {
        this.observer.observe(element)
      }
    }
    if (hotkeys) window.addEventListener("keydown", this.hotkeys)
    else window.removeEventListener("keydown", this.hotkeys)
    // The opener of a site this render closed, for the focus it leaves.
    let opener
    for (const [was, its] of this.marks) {
      if (its && !marks.has(was) && !ids.has(was.id)) opener = its
    }
    this.marks = marks
    // Not from a field with unsent input: the visitor is typing there.
    if (own && site && !this.unsent.has(trail?.element)) {
      if (control) {
        const { id, dataset } = control
        marks.set(site, { element: control, id, on: dataset.hibikiOn, payload: dataset.hibikiWith })
      }
      const take = () => {
        site.focus()
        if (site.dataset.hibikiFocus === "select") site.select?.()
      }
      take()
      // Turbo hands focus back to the id that had it before a stream, one
      // frame after appending it, which is just after this. Take it again.
      const id = trail?.element.id
      if (id) {
        setTimeout(() => {
          if (site.isConnected && document.activeElement?.id === id) take()
        }, 0)
      }
    } else if (trail) {
      this.refocus(trail, opener)
    }
    if (this.unsent.size) this.restoreUnsent()
  }

  // A key pressed inside the island: the nearest control up from the
  // target whose key token matches. Not forward()'s nearest control, since
  // a field wired for `input` sits inside the form that takes Escape. A
  // key something else took (a nested island, the page's script) is left.
  key(event) {
    if (event.defaultPrevented || !heard(event)) return
    let control = event.target.closest?.(KEYED)
    while (control && this.element.contains(control)) {
      const action = control.closest(ISLAND) === this.element && keyAction(control, event, "")
      if (action) return this.press(control, event, action)
      control = control.parentElement?.closest(KEYED)
    }
  }

  // A key pressed anywhere: the island's first enabled control declaring
  // it `@window`, the root included. One an inside control answered has
  // its default prevented, and so is not heard here.
  hotkey(event) {
    if ((event.defaultPrevented && !hotkeyed.has(event)) || !heard(event)) return
    const typing = entering(event.target)
    for (const control of [this.element, ...this.element.querySelectorAll(HOTKEYED)]) {
      if (control.closest(ISLAND) !== this.element || control.matches(":disabled")) continue
      const action = keyAction(control, event, "window", typing)
      if (!action) continue
      hotkeyed.add(event)
      return this.press(control, event, action)
    }
  }

  // A matched key is the control's gesture, so its default goes. A fallback
  // control on an island that is not ready stands aside: a key has no
  // native destination, but its default may be the form's own submit.
  press(control, event, action) {
    if ("hibikiFallback" in control.dataset && this.state !== "ready") return
    event.preventDefault()
    this.run(control, event, action)
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
    this.run(control, event, token.slice(event.type.length + 2))
  }

  // From a control's matched token to the wire.
  run(control, event, action) {
    // A fallback control's native behavior IS the degraded path: unless
    // the island is `ready`, stand aside — no perform, no queueing — and
    // the browser follows the href or submits the form to its own
    // action=. Deliberately not the connect-window queue: a queued
    // gesture renders nothing until the link comes up, while the
    // control's destination answers immediately. Two touches before
    // stepping back: a confirm: still gates the native behavior
    // (scripts are running, so a destructive submit must not slip past
    // the dialog), and the form's CSRF token is freshened.
    const fallback = "hibikiFallback" in control.dataset
    if (fallback && this.state !== "ready") {
      const message = control.dataset.hibikiConfirm
      if (message && !window.confirm(message)) return event.preventDefault?.()
      return freshenToken(control)
    }

    // Before the confirm, not after: declining must not let the form (or
    // a fallback control's navigation) proceed. Optional call because the
    // `visible` pseudo-event arrives as a plain object.
    if (event.type === "submit" || fallback) event.preventDefault?.()

    const message = control.dataset.hibikiConfirm
    if (message && !window.confirm(message)) return

    // The payload is built when the action actually fires, so a debounced
    // input sends what the user finished typing rather than the first
    // keystroke that started the timer.
    const wait = Number(control.dataset.hibikiDebounce)
    const fire = () => this.send(control, event, action)
    if (wait > 0) {
      const field = event.target
      if (event.type !== "keydown" && typed(field)) {
        this.unsent.set(field, {
          value: field.value,
          start: field.selectionStart,
          end: field.selectionEnd
        })
      }
      this.debounce(control, action, wait, () => {
        fire()
        // Sent: from here the server's value for the field wins again.
        if (!this.timers.get(control)?.size) this.unsent.delete(field)
      })
    } else {
      this.flush()
      fire()
    }
  }

  // A render drew these fields without the text typed since their last
  // send. A morph kept the element; a replace swapped in another with the
  // same id (the pending send still reads the detached one, whose value is
  // intact). The selection is the one the last keystroke left, restored
  // because assigning a value moves the caret to the end.
  restoreUnsent() {
    for (const [field, { value, start, end }] of this.unsent) {
      const live = field.isConnected ? field : field.id && document.getElementById(field.id)
      if (!live || !typed(live) || live.value === value) continue
      live.value = value
      if (start != null && live === document.activeElement) live.setSelectionRange(start, end)
    }
  }

  // Run every pending debounce now, oldest first.
  flush() {
    const runs = [...this.pending]
    this.pending.clear()
    for (const [id, run] of runs) {
      clearTimeout(id)
      run()
    }
  }

  send(control, event, action) {
    const payload = control.dataset.hibikiWith
      ? JSON.parse(control.dataset.hibikiWith)
      : {}
    if (event.type === "submit") {
      Object.assign(payload, formPayload(control))
    } else if (control.name && (event.type === "change" || event.type === "input")) {
      payload[payloadKey(control.name)] = controlValue(control)
    }
    // perform stamps `hbk` after this merge, so a field literally named hbk
    // loses to the seq rather than corrupting it.
    const seq = this.perform(action, payload)
    // The send failed on a socket believed live (perform already marked the
    // island offline). The gesture's default was prevented in dispatch, so
    // for a fallback control honor the contract by hand — the action never
    // left the machine, so the native behavior cannot double-fire.
    if (seq === undefined && "hibikiFallback" in control.dataset) {
      return this.fallthrough(control)
    }
    this.trackControl(seq, control)
    // Resetting is right for an "add" form and wrong for an edit one: it
    // runs synchronously, before the server has replied, so a failed commit
    // would discard what the user typed.
    if (event.type === "submit" && control.dataset.hibikiReset !== "false") {
      control.reset()
    }
  }

  // The native behavior the intercepted event would have had. submit(),
  // not requestSubmit(): the submit event already fired and was prevented,
  // and re-dispatching it would loop straight back through the delegated
  // listener.
  fallthrough(control) {
    if (control instanceof HTMLFormElement) {
      freshenToken(control)
      control.submit()
    } else if (control.href) {
      window.location.assign(control.href)
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
    const run = () => {
      byAction.delete(action)
      this.pending.delete(id)
      fire()
    }
    const id = setTimeout(run, wait)
    byAction.set(action, id)
    this.pending.set(id, run)
  }
}

export { HibikiController }

// The public seam without the Stimulus lookup (the header's "App JS
// reaching the graph"): fire an action through the subscription of the
// island CONTAINING element. Same return contract as perform — the seq
// when accepted, undefined when dropped or when no island contains the
// element (a structural mistake, hence the warn; the offline case stays
// quiet because it is expected weather).
export function performOn(element, action, payload = {}) {
  const island = islandFor(element)
  if (island) return island.perform(action, payload)
  console.warn("hibiki: performOn found no island containing", element)
  return undefined
}

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
