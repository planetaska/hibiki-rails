// Connection state, and the silent drop it was written to fix.
//
// The island's consumer opens its OWN websocket, and on the Turbo-broadcast
// path it does not start opening it until Turbo's stream source has confirmed
// — so the window between "the page is painted and looks live" and "the
// subscription is confirmed" serialises three round trips. Measured against
// generated output: 33–47 ms on localhost, ~327 ms with 150 ms of injected
// uplink latency, and about a second on a real remote link. Clicks in it used
// to produce no frame, no throw, and no console error.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import {
  island, mount, unmount, performed, sent, subscriptions,
  connectAll, disconnectAll, receive, flush
} from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

const button = `<button id="go" data-hibiki-on="click->increment"></button>`
const state = (root) => root.dataset.hibikiState
const busy = (element) => element.hasAttribute("data-hibiki-busy")

describe("data-hibiki-state", () => {
  it("is connecting from the first painted frame", async () => {
    const root = await mount(island(button), { autoConnect: false })
    expect(state(root)).toBe("connecting")
  })

  it("becomes ready when the server confirms the subscription", async () => {
    const root = await mount(island(button), { autoConnect: false })
    await connectAll()
    expect(state(root)).toBe("ready")
  })

  it("becomes offline when the socket drops", async () => {
    const root = await mount(island(button))
    await disconnectAll()
    expect(state(root)).toBe("offline")
  })

  it("returns to ready on reconnect", async () => {
    const root = await mount(island(button))
    await disconnectAll()
    await connectAll()
    expect(state(root)).toBe("ready")
  })
})

describe("the perform queue", () => {
  it("queues clicks made in the connect window and flushes them in order", async () => {
    const root = await mount(
      island(`<button data-hibiki-on="click->first"></button>
              <button data-hibiki-on="click->second"></button>`),
      { autoConnect: false }
    )
    for (const control of root.querySelectorAll("button")) control.click()
    expect(performed).toEqual([])

    await connectAll()

    expect(performed).toEqual([["first", {}], ["second", {}]])
    expect(sent.map(([, payload]) => payload.hbk)).toEqual([1, 2])
  })

  // A queued click is a click the user is waiting on, so it opens its busy
  // record at the gesture, not at the flush.
  it("counts a queued action as busy from the moment it was made", async () => {
    const root = await mount(island(button), { autoConnect: false })
    root.querySelector("#go").click()

    await vi.advanceTimersByTimeAsync(150)
    expect(busy(root)).toBe(true)

    await connectAll()
    await receive({ ack: sent[0][1].hbk, dropped: true })
    expect(busy(root)).toBe(false)
  })

  // The Turbo-broadcast path, which is what generated apps use: the client
  // awaits the element's own stream source before it even creates the
  // subscription, so the whole await is dead time for clicks.
  it("covers the await on the element's turbo stream source", async () => {
    const root = await mount(
      island(`<turbo-cable-stream-source></turbo-cable-stream-source>${button}`),
      { autoConnect: false }
    )
    expect(subscriptions).toEqual([])

    root.querySelector("#go").click()
    expect(performed).toEqual([])

    root.querySelector("turbo-cable-stream-source").setAttribute("connected", "")
    await flush()
    await connectAll()

    expect(performed).toEqual([["increment", {}]])
  })
})

describe("across a reconnect", () => {
  // Reconnecting builds a FRESH graph server-side with default state, so
  // replaying intent formed against the old one is worse than dropping it —
  // and unlike the connect window, the island has been saying `offline` the
  // whole time.
  it("does not queue an action made while offline", async () => {
    const root = await mount(island(button))
    await disconnectAll()

    root.querySelector("#go").click()
    await connectAll()

    expect(performed).toEqual([])
  })

  // Their acks are never coming: the graph that would have sent them is gone.
  it("settles every outstanding record when the socket drops", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(150)
    expect(busy(root)).toBe(true)

    await disconnectAll()

    expect(busy(root)).toBe(false)
    expect(state(root)).toBe("offline")
  })

  it("keeps working normally once the link is back", async () => {
    const root = await mount(island(button))
    await disconnectAll()
    await connectAll()

    root.querySelector("#go").click()

    expect(performed).toEqual([["increment", {}]])
  })
})
