// Replaceable sends: a control marked `data-hibiki-replaceable` sends nothing
// while an action of its kind (the action name and the payload's keys, the
// server's rule) from the island waits for its ack. The new one is held, a
// newer one replaces it, and the ack sends it. The server skips what is
// replaced in its queue; this keeps a tab from sending it at all.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import {
  island, mount, unmount, sent, receive, connectAll, disconnectAll, controller
} from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

const DELAY = 150
const GRACE = 60
const CEILING = 10000

const search = `<input id="q" name="q" data-hibiki-on="input->search" data-hibiki-replaceable="true">`
const save = `<button id="save" data-hibiki-on="click->save"></button>`

const type = (input, text) => {
  input.value = text
  input.dispatchEvent(new Event("input", { bubbles: true }))
}

// [action, payload without hbk, hbk] for every frame sent.
const frames = () => sent.map(([action, { hbk, ...payload }]) => [action, payload, hbk])

describe("a replaceable control", () => {
  it("holds a send while one of its kind waits for its ack, and sends it on the ack", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")

    expect(frames()).toEqual([["search", { q: "a" }, 1]])

    await receive({ ack: 1 })
    expect(frames()).toEqual([["search", { q: "a" }, 1], ["search", { q: "ab" }, 2]])
  })

  it("sends only the newest of the ones held", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    for (const text of ["a", "ab", "abc", "abcd"]) type(q, text)

    await receive({ ack: 1 })
    expect(frames()).toEqual([["search", { q: "a" }, 1], ["search", { q: "abcd" }, 2]])
  })

  it("holds again behind the one it just sent", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")
    await receive({ ack: 1 })
    type(q, "abc")

    expect(frames().map(([, payload]) => payload.q)).toEqual(["a", "ab"])
    await receive({ ack: 2 })
    expect(frames().map(([, payload]) => payload.q)).toEqual(["a", "ab", "abc"])
  })

  // The server skipped the one in flight because the next replaced it.
  it("sends it on a dropped ack", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")

    await receive({ ack: 1, dropped: true })
    expect(frames().at(-1)).toEqual(["search", { q: "ab" }, 2])
  })

  it("sends it when the one in flight stalls", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")

    await vi.advanceTimersByTimeAsync(CEILING)
    expect(frames().at(-1)).toEqual(["search", { q: "ab" }, 2])
  })

  // Without it, a click on Save would overtake the search typed before it.
  it("is sent before any other action from the island", async () => {
    const root = await mount(island(search + save))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")
    root.querySelector("#save").click()

    expect(frames()).toEqual([
      ["search", { q: "a" }, 1],
      ["search", { q: "ab" }, 2],
      ["save", {}, 3]
    ])
  })

  it("is sent before a public perform", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")
    controller(root).perform("reorder", { ids: [2, 1] })

    expect(frames().map(([action]) => action)).toEqual(["search", "search", "reorder"])
  })

  // The one sent early is in flight now, so the ack of the first does not
  // send a newer one past it.
  it("waits for every one of its kind in flight", async () => {
    const root = await mount(island(search + save))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")
    root.querySelector("#save").click()
    type(q, "abc")

    await receive({ ack: 1 })
    expect(frames()).toHaveLength(3)
    await receive({ ack: 2 })
    expect(frames().at(-1)).toEqual(["search", { q: "abc" }, 4])
  })

  it("sends what different controls held in the order they were held", async () => {
    const root = await mount(island(
      search + `<select id="sort" name="sort" data-hibiki-on="change->set_sort" data-hibiki-replaceable>
        <option>name</option><option>level</option></select>`
    ))
    const q = root.querySelector("#q")
    const sort = root.querySelector("#sort")
    const choose = (value) => {
      sort.value = value
      sort.dispatchEvent(new Event("change", { bubbles: true }))
    }
    type(q, "a") // 1
    choose("name") // 2
    type(q, "ab") // held
    choose("level") // held

    await receive({ ack: 2 })
    expect(frames().map(([action, payload]) => payload.q ?? payload.sort)).toEqual(["a", "name", "ab", "level"])
  })

  it("keeps the control busy while its send is held", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")
    await vi.advanceTimersByTimeAsync(DELAY)

    expect(q.hasAttribute("data-hibiki-busy")).toBe(true)
    await receive({ ack: 1 })
    expect(q.hasAttribute("data-hibiki-busy")).toBe(true)
    // The first trip settles after its grace; the one it released is still out.
    await vi.advanceTimersByTimeAsync(GRACE)
    expect(q.hasAttribute("data-hibiki-busy")).toBe(true)
    await receive({ ack: 2 })
    await vi.advanceTimersByTimeAsync(GRACE)
    expect(q.hasAttribute("data-hibiki-busy")).toBe(false)
  })

  it("drops what it held when the link drops", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")

    await disconnectAll()
    await connectAll()
    await receive({ ack: 1 })
    expect(frames()).toEqual([["search", { q: "a" }, 1]])
  })
})

describe("what is not held", () => {
  it("a control without the mark", async () => {
    const root = await mount(island(`<input id="q" name="q" data-hibiki-on="input->search">`))
    const q = root.querySelector("#q")
    type(q, "a")
    type(q, "ab")

    expect(frames().map(([, payload, hbk]) => [payload.q, hbk])).toEqual([["a", 1], ["ab", 2]])
  })

  // Inline Edit: one action on every field, each send naming only its own.
  it("the same action with different payload keys", async () => {
    const field = (name) =>
      `<input id="${name}" name="${name}" data-hibiki-on="input->set_field" data-hibiki-replaceable>`
    const root = await mount(island(field("name") + field("notes")))
    type(root.querySelector("#name"), "Ada")
    type(root.querySelector("#notes"), "hi")

    expect(frames()).toEqual([["set_field", { name: "Ada" }, 1], ["set_field", { notes: "hi" }, 2]])
  })

  it("a send after the one in flight was acked", async () => {
    const root = await mount(island(search))
    const q = root.querySelector("#q")
    type(q, "a")
    await receive({ ack: 1 })
    type(q, "ab")

    expect(frames().at(-1)).toEqual(["search", { q: "ab" }, 2])
  })
})
