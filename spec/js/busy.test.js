// Pending state: what the island says while a round trip is in flight.
//
// Every reactivity in this stack is server-side, so every gesture is a round
// trip. The client is the only place the fact "a request is out" exists — the
// server cannot tell you, because the message saying so would arrive one full
// round trip after the moment it was needed.
//
// Both timers here (the show-delay and the ceiling) are only assertable under
// fake timers: a headless browser is a fine second opinion, but "the attribute
// never appeared" is a negative timing claim, and that is racy anywhere else.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, performed, sent, receive, flush } from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

const DELAY = 150
const GRACE = 60
const CEILING = 10000

const button = `<button id="go" data-hibiki-on="click->increment"></button>`
const busy = (element) => element.hasAttribute("data-hibiki-busy")
const seqOf = (index = 0) => sent[index][1].hbk

// Every transition of the root's busy flag, so "it never flickered" is a
// statement about what happened rather than about one sampled moment.
const watchBusy = (root) => {
  const log = []
  const observer = new MutationObserver(() => log.push(busy(root)))
  observer.observe(root, { attributeFilter: ["data-hibiki-busy"] })
  return log
}

describe("the seq", () => {
  it("stamps every perform with an increasing hbk", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    root.querySelector("#go").click()

    expect(sent.map(([, payload]) => payload.hbk)).toEqual([1, 2])
  })

  // `hbk` is a reserved payload key — the second one, after ActionCable's own
  // `action`. It is stamped after the FormData merge, so a field that happens
  // to be named hbk loses to the seq instead of corrupting it.
  it("wins over a form field of the same name", async () => {
    const root = await mount(
      island(`<form data-hibiki-on="submit->save"><input name="hbk" value="pwned"></form>`)
    )
    root.querySelector("form").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    expect(sent[0][1].hbk).toBe(1)
    expect(performed).toEqual([["save", {}]])
  })
})

describe("the show-delay", () => {
  // The failure mode this exists to prevent is "hibiki added flicker": a
  // localhost round trip is 18–25 ms, and a spinner shown for 18 ms reads as
  // jank, which is worse than no indicator at all.
  it("says nothing about a trip that finishes inside it", async () => {
    const root = await mount(island(button))
    const log = watchBusy(root)
    root.querySelector("#go").click()

    await vi.advanceTimersByTimeAsync(20)
    await receive({ ack: seqOf(), dropped: true })
    await vi.advanceTimersByTimeAsync(DELAY * 4)

    expect(log).toEqual([])
    expect(busy(root)).toBe(false)
  })

  it("stamps the island once a trip outlasts it, and clears on the ack", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()

    await vi.advanceTimersByTimeAsync(DELAY - 1)
    expect(busy(root)).toBe(false)

    await vi.advanceTimersByTimeAsync(1)
    expect(busy(root)).toBe(true)
    expect(root.getAttribute("aria-busy")).toBe("true")

    await receive({ ack: seqOf() })
    await vi.advanceTimersByTimeAsync(GRACE)
    expect(busy(root)).toBe(false)
    expect(root.hasAttribute("aria-busy")).toBe(false)
  })

  // The user has been waiting since the FIRST action, so a second one must
  // not push the indicator further away.
  it("is not restarted by a second overlapping action", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(100)
    root.querySelector("#go").click()

    await vi.advanceTimersByTimeAsync(50)
    expect(busy(root)).toBe(true)
  })
})

describe("settling", () => {
  // The whole reason the ack exists. The core's equality gate lets ordinary
  // gestures — paging to the page you are already on, a search that does not
  // change the query, a destroy of a row another tab already deleted —
  // produce zero bytes, so waiting for a render would hang forever.
  it("clears an action that produced no render at all", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)
    expect(busy(root)).toBe(true)

    await receive({ ack: seqOf() })
    await vi.advanceTimersByTimeAsync(GRACE)

    expect(busy(root)).toBe(false)
  })

  // The ack travels the island's own socket; a Turbo broadcast for the same
  // batch takes a pubsub hop and arrives a few ms later. The grace window is
  // for that render, not for a render that is never coming.
  it("waits out the grace window before clearing", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    await receive({ ack: seqOf() })
    expect(busy(root)).toBe(true)

    await vi.advanceTimersByTimeAsync(GRACE - 1)
    expect(busy(root)).toBe(true)
    await vi.advanceTimersByTimeAsync(1)
    expect(busy(root)).toBe(false)
  })

  it("skips the grace window when a render already landed", async () => {
    const root = await mount(island(`<div id="list"></div>${button}`))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    await receive({ html: `<div id="list">painted</div>` })
    await receive({ ack: seqOf() })

    expect(busy(root)).toBe(false)
  })

  // `dropped` means the action never reached the graph — a torn-down
  // subscription, or a queue closed by teardown. Nothing is coming, so there
  // is nothing to wait for.
  it("clears a dropped ack immediately", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    await receive({ ack: seqOf(), dropped: true })

    expect(busy(root)).toBe(false)
  })

  // Depth, not a boolean: typing while a page loads is one island with two
  // actions outstanding, and the first answer must not clear the second.
  it("stays busy until every outstanding action has settled", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    await receive({ ack: seqOf(0), dropped: true })
    expect(busy(root)).toBe(true)

    await receive({ ack: seqOf(1), dropped: true })
    expect(busy(root)).toBe(false)
  })

  it("ignores an ack for a seq it is not waiting on", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    await receive({ ack: 99, dropped: true })

    expect(busy(root)).toBe(true)
  })

  it("does not treat an ack frame as a fragment or a value", async () => {
    const root = await mount(island(`<span data-hibiki-value="count">0</span>${button}`))
    root.querySelector("#go").click()
    await receive({ ack: seqOf(), dropped: true })

    expect(root.querySelector("[data-hibiki-value]").textContent).toBe("0")
  })
})

describe("the ceiling", () => {
  // On a bad link "we lost it" beats "nothing happened" — a silently cleared
  // indicator claims the opposite of what happened.
  it("declares the island stalled rather than clearing silently", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()

    await vi.advanceTimersByTimeAsync(CEILING)

    expect(busy(root)).toBe(false)
    expect(root.dataset.hibikiState).toBe("stalled")
  })

  it("recovers on the next ack, however late", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(CEILING)

    await receive({ ack: seqOf() })

    expect(root.dataset.hibikiState).toBe("ready")
  })

  it("does not fire for a trip that already settled", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await receive({ ack: seqOf(), dropped: true })

    await vi.advanceTimersByTimeAsync(CEILING * 2)

    expect(root.dataset.hibikiState).toBe("ready")
  })
})

describe("the firing control", () => {
  it("carries its own flag, so per-row feedback needs no server state", async () => {
    const root = await mount(
      island(`<button id="a" data-hibiki-on="click->destroy"></button>
              <button id="b" data-hibiki-on="click->destroy"></button>`)
    )
    root.querySelector("#a").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    expect(busy(root.querySelector("#a"))).toBe(true)
    expect(busy(root.querySelector("#b"))).toBe(false)

    await receive({ ack: seqOf(), dropped: true })
    expect(busy(root.querySelector("#a"))).toBe(false)
  })

  // A control that fires while the island is already busy has missed the
  // show-delay, so it has to be stamped on the spot.
  it("is stamped immediately when the island is already busy", async () => {
    const root = await mount(
      island(`<button id="a" data-hibiki-on="click->destroy"></button>
              <button id="b" data-hibiki-on="click->destroy"></button>`)
    )
    root.querySelector("#a").click()
    await vi.advanceTimersByTimeAsync(DELAY)
    root.querySelector("#b").click()

    expect(busy(root.querySelector("#b"))).toBe(true)
  })

  // Controls INSIDE a replaced fragment are cleared by the swap itself (the
  // incoming HTML carries no flag, and an idiomorph repaint syncs attributes).
  // Controls outside it — the search field, the island root — are the client's
  // own to clear.
  it("clears a control that survives the swap", async () => {
    const root = await mount(
      island(`<input id="q" name="q" data-hibiki-on="input->search">
              <div id="list"></div>`)
    )
    const input = root.querySelector("#q")
    input.value = "ged"
    input.dispatchEvent(new Event("input", { bubbles: true }))
    await vi.advanceTimersByTimeAsync(DELAY)
    expect(busy(input)).toBe(true)

    await receive({ html: `<div id="list">painted</div>` })
    await receive({ ack: seqOf() })

    expect(busy(input)).toBe(false)
  })
})

describe("teardown", () => {
  it("drops every outstanding record when the island disconnects", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()
    await vi.advanceTimersByTimeAsync(DELAY)

    await unmount()
    await vi.advanceTimersByTimeAsync(CEILING * 2)

    // The ceiling timer for that trip must not outlive the controller.
    expect(root.dataset.hibikiState).not.toBe("stalled")
  })

  it("cancels a pending show-delay on disconnect", async () => {
    const root = await mount(island(button))
    root.querySelector("#go").click()

    await unmount()
    await vi.advanceTimersByTimeAsync(DELAY * 2)

    expect(busy(root)).toBe(false)
  })
})

// Nothing above should have changed what a payload looks like.
it("leaves the action and its payload otherwise untouched", async () => {
  const root = await mount(
    island(`<button data-hibiki-on="click->destroy" data-hibiki-with='{"id":7}'></button>`)
  )
  root.querySelector("button").click()
  await flush()

  expect(performed).toEqual([["destroy", { id: 7 }]])
})
