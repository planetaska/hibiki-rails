// History entries: a `{ url, push }` frame (transmit_url(history: :push))
// makes one when it answers this tab's own action, and the island root's
// `popstate->action` token answers Back and Forward over them.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, receive, performed, sent, flush } from "./support/island.js"

beforeEach(() => {
  vi.useFakeTimers()
  window.history.replaceState(null, "", "/wizard")
  window.Turbo = { cache: { exemptPageFromCache: vi.fn() } }
  reload = vi.spyOn(window.location, "reload").mockImplementation(() => {})
})
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
  delete window.Turbo
  reload.mockRestore()
})

let reload

const wizard = (inner = "", attrs = 'data-hibiki-on="popstate->visit"') =>
  island(`<button data-hibiki-on="click->turn">Next</button>${inner}`, attrs)

// An action of this tab's, answered by a pushed URL and then acked.
const turn = async (url) => {
  document.querySelector("button").click()
  await receive({ url, push: true })
  await receive({ ack: sent.at(-1)[1].hbk })
}

// What the browser does on Back: the entry's URL and state, then the event.
const pop = async (url, state) => {
  window.history.replaceState(state, "", url)
  const event = new PopStateEvent("popstate", { state })
  window.dispatchEvent(event)
  await flush()
  return event
}

describe("a pushed url", () => {
  it("adds a history entry when it answers this tab's action", async () => {
    await mount(wizard())
    const length = window.history.length
    await turn("/wizard?step=2")

    expect(window.history.length).toBe(length + 1)
    expect(window.location.search).toBe("?step=2")
  })

  it("gives the entry it leaves and the one it makes its key in place of Turbo's state", async () => {
    await mount(wizard())
    window.history.replaceState({ turbo: { restorationIdentifier: "r1" }, mine: 1 }, "")
    const replace = vi.spyOn(window.history, "replaceState")
    await turn("/wizard?step=2")

    const left = replace.mock.calls.at(-1)[0]
    expect(left.turbo).toBeUndefined()
    expect(left.mine).toBe(1)
    expect(left.hibiki).toBeTruthy()
    expect(window.history.state).toEqual(left)
  })

  it("keeps the page out of Turbo's snapshot cache", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")

    expect(window.Turbo.cache.exemptPageFromCache).toHaveBeenCalled()
  })

  it("adds no entry for the URL the bar already shows", async () => {
    await mount(wizard())
    const length = window.history.length
    await turn("/wizard")

    expect(window.history.length).toBe(length)
  })

  it("replaces when nothing of this tab's is in flight", async () => {
    await mount(wizard())
    const length = window.history.length
    await receive({ url: "/wizard?step=2", push: true })

    expect(window.history.length).toBe(length)
    expect(window.location.search).toBe("?step=2")
  })

  it("refuses a cross-origin URL", async () => {
    await mount(wizard())
    const length = window.history.length
    await turn("https://evil.example/phish")

    expect(window.history.length).toBe(length)
    expect(window.location.pathname).toBe("/wizard")
  })
})

describe("popstate", () => {
  it("performs the root's action with the popped entry's query", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    await pop("/wizard?step=1&tags[]=a&tags[]=b", window.history.state)

    expect(performed.at(-1)).toEqual(["visit", { step: "1", tags: ["a", "b"] }])
  })

  it("sends the control's own payload beneath the query", async () => {
    await mount(wizard("", `data-hibiki-on="popstate->visit" data-hibiki-with='{"from":"bar","step":"0"}'`))
    await turn("/wizard?step=2")
    await pop("/wizard?step=1", window.history.state)

    expect(performed.at(-1)).toEqual(["visit", { from: "bar", step: "1" }])
  })

  it("takes back the entry Turbo adopted", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    const state = window.history.state
    // What Turbo, hearing the event first, does to an entry without its state.
    const adopt = () => window.history.replaceState({ turbo: { restorationIdentifier: "r2" } }, "")
    window.addEventListener("popstate", adopt, true)
    window.history.replaceState(state, "", "/wizard")
    const event = new PopStateEvent("popstate", { state })
    adopt()
    window.dispatchEvent(event)
    window.removeEventListener("popstate", adopt, true)
    await flush()

    expect(window.history.state).toEqual(state)
    expect(reload).not.toHaveBeenCalled()
  })

  it("leaves an entry with no key to the page", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    await pop("/elsewhere", null)
    await pop("/elsewhere", { turbo: { restorationIdentifier: "r3" } })

    expect(performed.map(([action]) => action)).toEqual(["turn"])
    expect(reload).not.toHaveBeenCalled()
  })

  it("loads the page afresh for an entry whose island is gone", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    await pop("/wizard?step=1", { hibiki: "an-earlier-island" })

    expect(performed.map(([action]) => action)).toEqual(["turn"])
    expect(reload).toHaveBeenCalled()
  })

  it("corrects the bar in place when the action refuses the popped URL", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    const length = window.history.length
    await pop("/wizard?step=9", window.history.state)
    await receive({ url: "/wizard?step=2", push: true })

    expect(window.history.length).toBe(length)
    expect(window.location.search).toBe("?step=2")
    expect(window.history.state.hibiki).toBeTruthy()
  })

  it("puts the bar back when the action changes nothing", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    const length = window.history.length
    await pop("/wizard", window.history.state)
    await receive({ ack: sent.at(-1)[1].hbk })
    await vi.advanceTimersByTimeAsync(60)

    expect(window.location.search).toBe("?step=2")
    expect(window.history.length).toBe(length)
  })

  it("keeps the popped URL when the channel sends it back", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    await pop("/wizard?step=1", window.history.state)
    await receive({ url: "/wizard?step=1", push: true })
    await receive({ ack: sent.at(-1)[1].hbk })
    await vi.advanceTimersByTimeAsync(60)

    expect(window.location.search).toBe("?step=1")
  })

  it("pushes again once the pop has been acked", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    await pop("/wizard", window.history.state)
    await receive({ url: "/wizard", push: true })
    await receive({ ack: sent.at(-1)[1].hbk })
    await vi.advanceTimersByTimeAsync(60) // busyGrace: the trip settles
    const length = window.history.length
    await turn("/wizard?step=2")

    expect(window.history.length).toBe(length + 1)
  })

  it("loads the page afresh when the island declares no popstate", async () => {
    await mount(wizard("", ""))
    await turn("/wizard?step=2")
    await pop("/wizard", window.history.state)

    expect(performed.map(([action]) => action)).toEqual(["turn"])
    expect(reload).toHaveBeenCalled()
  })

  it("loads the page afresh once the island has left", async () => {
    await mount(wizard())
    await turn("/wizard?step=2")
    const state = window.history.state
    document.body.innerHTML = ""
    await flush()
    const count = performed.length
    await pop("/wizard", state)

    expect(performed.length).toBe(count)
    expect(reload).toHaveBeenCalled()
  })
})
