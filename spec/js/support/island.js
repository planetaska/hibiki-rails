// A real Stimulus application driving the real controller, against a stubbed
// Action Cable consumer. Everything below the subscription is genuine —
// delegation, the ownership guard, token matching, payload building — so
// these tests exercise the same code path a browser does.
import { vi } from "vitest"
import { Application } from "@hotwired/stimulus"

// Recorded by the consumer stub. Reset per example by mount().
export const subscriptions = []
export const performed = []

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create(params, handlers) {
        const subscription = {
          params,
          handlers,
          perform: (action, payload) => performed.push([action, payload]),
          unsubscribe: () => {}
        }
        subscriptions.push(subscription)
        return subscription
      }
    }
  })
}))

// Let queued microtasks and any due timers run. Async so it works under
// vitest's fake timers, which the debounce tests turn on.
export const flush = async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.advanceTimersByTimeAsync(0)
}

let application

export async function mount(html) {
  subscriptions.length = 0
  performed.length = 0
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
}

// The island wrapper every example builds its controls inside.
export const island = (inner, attrs = "") =>
  `<div data-controller="hibiki" data-hibiki-channel-value="TestChannel"
        data-hibiki-cid-value="c1" ${attrs}>${inner}</div>`
