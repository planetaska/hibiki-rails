// The blessed public seam: `perform(action, payload)` on the island
// controller, and the `performOn` export that finds the island for you.
// The contract under test is the return value — truthy (the trip's seq)
// means accepted and a repaint is coming; undefined means dropped and the
// caller owns recovery. Nothing queues across an offline gap.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import {
  island, mount, unmount, performed, sent, cable,
  connectAll, disconnectAll, controller, client, flush
} from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

const markup = island(`<fieldset id="rows"><div id="row"></div></fieldset>`)

describe("perform as public API on the island controller", () => {
  it("returns the trip's seq and sends the frame with hbk stamped", async () => {
    const root = await mount(markup)

    const seq = controller(root).perform("nested_move", { path: "credits/c1", to: 2 })

    expect(seq).toBe(1)
    expect(performed).toEqual([["nested_move", { path: "credits/c1", to: 2 }]])
    expect(sent[0][1].hbk).toBe(1)
  })

  it("stamps the seq over a payload field literally named hbk", async () => {
    const root = await mount(markup)

    controller(root).perform("save", { hbk: "forged" })

    expect(sent[0][1].hbk).toBe(1)
  })

  it("opens a busy record for the trip like any declared action", async () => {
    const root = await mount(markup)

    controller(root).perform("save")
    await vi.advanceTimersByTimeAsync(150)

    expect(root.hasAttribute("data-hibiki-busy")).toBe(true)
  })

  it("accepts (truthy) and queues during the initial connect window", async () => {
    const root = await mount(markup, { autoConnect: false })

    const seq = controller(root).perform("save")

    expect(seq).toBe(1)
    expect(performed).toEqual([])

    await connectAll()
    expect(performed).toEqual([["save", {}]])
  })

  // The regression this release fixes: the offline gap used to drop the
  // payload but still return the truthy seq — a lie once the return value
  // is the public contract.
  it("returns undefined during an offline gap, and does not queue", async () => {
    const root = await mount(markup)
    await disconnectAll()

    const seq = controller(root).perform("save")

    expect(seq).toBeUndefined()
    expect(performed).toEqual([])

    await connectAll()
    expect(performed).toEqual([])
  })

  it("returns undefined when the socket is found dead at send", async () => {
    const root = await mount(markup)
    cable.sendResult = false

    const seq = controller(root).perform("save")

    expect(seq).toBeUndefined()
    expect(root.dataset.hibikiState).toBe("offline")
  })
})

describe("performOn", () => {
  it("fires through the island containing the element and returns its seq", async () => {
    await mount(markup)
    const { performOn } = await client()

    const seq = performOn(document.querySelector("#row"), "nested_move", { to: 0 })

    expect(seq).toBe(1)
    expect(performed).toEqual([["nested_move", { to: 0 }]])
  })

  it("accepts the island element itself", async () => {
    const root = await mount(markup)
    const { performOn } = await client()

    expect(performOn(root, "save")).toBe(1)
    expect(performed).toEqual([["save", {}]])
  })

  it("relays the dropped contract from an offline island", async () => {
    await mount(markup)
    await disconnectAll()
    const { performOn } = await client()

    expect(performOn(document.querySelector("#row"), "save")).toBeUndefined()
    expect(performed).toEqual([])
  })

  it("returns undefined and warns for an element outside any island", async () => {
    await mount(markup)
    const { performOn } = await client()
    const outside = document.createElement("div")
    document.body.appendChild(outside)
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})

    expect(performOn(outside, "save")).toBeUndefined()

    expect(warn).toHaveBeenCalledOnce()
    expect(performed).toEqual([])
    warn.mockRestore()
  })

  it("forgets an island once it disconnects", async () => {
    const root = await mount(markup)
    const row = document.querySelector("#row")
    const { performOn } = await client()

    // Detach the island and let Stimulus disconnect it. The detached tree
    // still has its parent chain, so only the registry removal can make
    // this walk come up empty.
    root.remove()
    await flush()
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})

    expect(performOn(row, "save")).toBeUndefined()

    expect(warn).toHaveBeenCalledOnce()
    expect(performed).toEqual([])
    warn.mockRestore()
  })
})
