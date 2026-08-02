// A real Stimulus application driving the real controller, against a stubbed
// Action Cable consumer. Everything below the subscription is genuine —
// delegation, the ownership guard, token matching, payload building — so
// these tests exercise the same code path a browser does.
import { vi } from "vitest"
import { Application } from "@hotwired/stimulus"

// Recorded by the consumer stub. Reset per example by mount().
export const subscriptions = []
export const performed = []
// The same performs with their transport bookkeeping intact. `performed`
// strips `hbk` so payload examples stay about payloads; the busy examples
// read the seq from here.
export const sent = []

// Whether the stub confirms a new subscription on its own. A real server's
// confirmation is a round trip, so it is deferred to a microtask rather than
// fired inside create() — which is also the only order the client can
// survive, since it assigns this.subscription from create's return value.
// Set false to hold an island in its connect window.
export const cable = { autoConnect: true }

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create(params, handlers) {
        const subscription = {
          params,
          handlers,
          perform: (action, payload) => {
            const { hbk, ...rest } = payload
            sent.push([action, payload])
            performed.push([action, rest])
          },
          unsubscribe: () => {}
        }
        subscriptions.push(subscription)
        if (cable.autoConnect) queueMicrotask(() => handlers.connected())
        return subscription
      }
    }
  })
}))

// The server confirmed (or re-confirmed) every live subscription.
export const connectAll = async () => {
  for (const subscription of subscriptions) subscription.handlers.connected()
  await flush()
}

// The socket dropped under every live subscription.
export const disconnectAll = async () => {
  for (const subscription of subscriptions) subscription.handlers.disconnected()
  await flush()
}

// Push a server frame at the most recently created subscription.
export const receive = async (data) => {
  subscriptions.at(-1).handlers.received(data)
  await flush()
}

// Let queued microtasks and any due timers run. Async so it works under
// vitest's fake timers, which the debounce tests turn on.
export const flush = async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.advanceTimersByTimeAsync(0)
}

let application

export async function mount(html, { autoConnect = true } = {}) {
  subscriptions.length = 0
  performed.length = 0
  sent.length = 0
  cable.autoConnect = autoConnect
  document.body.innerHTML = html

  const { default: HibikiController } = await import(
    "../../../app/assets/javascripts/hibiki.js"
  )
  application = Application.start()
  application.register("hibiki", HibikiController)
  await flush()
  return document.querySelector('[data-controller~="hibiki"]')
}

// Remove the element first and let Stimulus' own MutationObserver notice:
// application.stop() only stops the observers, it does not disconnect the
// contexts they already matched.
export async function unmount() {
  document.body.innerHTML = ""
  await flush()
  await application?.stop()
  application = undefined
  cable.autoConnect = true
}

// The island wrapper every example builds its controls inside.
export const island = (inner, attrs = "") =>
  `<div data-controller="hibiki" data-hibiki-channel-value="TestChannel"
        data-hibiki-cid-value="c1" ${attrs}>${inner}</div>`
