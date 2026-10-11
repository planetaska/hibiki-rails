// Trips: with reportTrips on, the island times each round trip and tells the
// server with its next action, under the reserved `hbt` key. Only the browser
// sees both the ack and the render land, so only it can say how long a
// visitor waited.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, controller, sent, receive, disconnectAll } from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

const GRACE = 60
const FOCUS_GRACE = 500
const CEILING = 10000

const page = island(
  `<button id="go" data-hibiki-on="click->increment"></button>
   <button id="more" data-hibiki-on="click->load_more"></button>
   <p id="note"></p>`
)

// Mount with reporting on. The static is the app's switch, so it is set on
// the class and put back.
const reporting = async (html = page) => {
  const root = await mount(html)
  const klass = controller(root).constructor
  klass.reportTrips = true
  restore = () => { klass.reportTrips = false }
  return root
}
let restore
afterEach(() => restore?.())

const click = (root, id = "go") => root.querySelector(`#${id}`).click()
const wait = (ms) => vi.advanceTimersByTimeAsync(ms)
const ack = (index = -1) => receive({ ack: sent.at(index)[1].hbk })
const hbt = (index = -1) => sent.at(index)[1].hbt

// A stamped <turbo-stream> arriving for `from`, as Turbo dispatches it.
const stream = (seq, from = "TestChannel/c1") => {
  const element = document.createElement("turbo-stream")
  element.setAttribute("target", "note")
  element.setAttribute("data-hibiki-seq", seq)
  element.setAttribute("data-hibiki-from", from)
  const event = new CustomEvent("turbo:before-stream-render", {
    bubbles: true,
    detail: { newStream: element, render: async () => {} }
  })
  document.dispatchEvent(event)
  return event.detail.render(element)
}

describe("with reporting off", () => {
  it("sends no trips", async () => {
    const root = await mount(page)
    click(root)
    await wait(20)
    await ack()
    await wait(GRACE)
    click(root)

    expect(sent).toHaveLength(2)
    expect("hbt" in sent[1][1]).toBe(false)
  })

  // Reserved like hbk: the server drops the key, so a field of that name
  // could never arrive anyway.
  it("keeps a payload field named hbt off the wire", async () => {
    const root = await mount(page)
    controller(root).perform("save", { hbt: "forged" })

    expect("hbt" in sent[0][1]).toBe(false)
  })
})

describe("a trip", () => {
  it("goes out with the next action, as its name, its ack and its paint", async () => {
    const root = await reporting()
    click(root)
    await wait(20)
    await receive({ html: `<p id="note">1</p>` })
    await wait(5)
    await ack()
    click(root, "more")

    expect(hbt(0)).toBeUndefined()
    expect(hbt()).toEqual([["increment", 25, 20]])
  })

  it("is sent once", async () => {
    const root = await reporting()
    click(root)
    await ack()
    await wait(GRACE)
    click(root)
    await ack()
    await wait(GRACE)
    click(root)

    expect(hbt(1)).toEqual([["increment", 0, null]])
    expect(hbt(2)).toEqual([["increment", 0, null]])
  })

  it("has no paint when nothing rendered", async () => {
    const root = await reporting()
    click(root)
    await wait(8)
    await ack()
    await wait(GRACE + FOCUS_GRACE + 1)
    await receive({ html: `<p id="note">someone else's</p>` })
    click(root)

    expect(hbt()).toEqual([["increment", 8, null]])
  })

  // The ack rides the island's socket and usually wins; the render is still
  // this trip's answer while the grace runs, and a little after.
  it("takes a render that lands after its ack", async () => {
    const root = await reporting()
    click(root)
    await wait(10)
    await ack()
    await wait(30)
    await receive({ html: `<p id="note">1</p>` })
    await wait(GRACE)
    click(root)

    expect(hbt()).toEqual([["increment", 10, 40]])
  })

  it("takes a render that lands after it settled, within the focus grace", async () => {
    const root = await reporting()
    click(root)
    await wait(10)
    await ack()
    await wait(GRACE + 100)
    await receive({ html: `<p id="note">1</p>` })
    click(root)

    expect(hbt()).toEqual([["increment", 10, 170]])
  })

  it("keeps the first render's time, not the last", async () => {
    const root = await reporting()
    click(root)
    await wait(10)
    await receive({ html: `<p id="note">1</p>` })
    await wait(10)
    await receive({ html: `<p id="note">2</p>` })
    await ack()
    click(root)

    expect(hbt()).toEqual([["increment", 20, 10]])
  })
})

describe("a Turbo stream", () => {
  it("is the paint when it is this island's", async () => {
    const root = await reporting()
    click(root)
    await wait(15)
    await stream(1)
    await ack()
    click(root)

    expect(hbt()).toEqual([["increment", 15, 15]])
  })

  it("is nobody's paint when it is another island's", async () => {
    const root = await reporting()
    click(root)
    await wait(15)
    await stream(1, "TestChannel/c2")
    await ack()
    await wait(GRACE)
    click(root)

    expect(hbt()).toEqual([["increment", 15, null]])
  })
})

describe("the list", () => {
  it("holds the last five", async () => {
    const root = await reporting()
    // Seven trips with nothing sent between them: opened together, acked
    // one at a time.
    for (let i = 0; i < 7; i++) controller(root).perform(`a${i}`)
    for (let i = 0; i < 7; i++) {
      await wait(1)
      await ack(i)
    }
    await wait(GRACE)
    click(root)

    expect(hbt().map(([action]) => action)).toEqual(["a2", "a3", "a4", "a5", "a6"])
  })

  it("leaves out a trip the server dropped", async () => {
    const root = await reporting()
    click(root)
    await receive({ ack: sent[0][1].hbk, dropped: true })
    click(root)

    expect(hbt()).toBeUndefined()
  })

  it("leaves out a trip that stalled", async () => {
    const root = await reporting()
    click(root)
    await wait(CEILING)
    click(root)

    expect(hbt()).toBeUndefined()
  })

  it("leaves out a trip the link dropped", async () => {
    const root = await reporting()
    click(root)
    await disconnectAll()

    expect(controller(root).trips).toEqual([])
  })

  it("wins over a payload field named hbt", async () => {
    const root = await reporting()
    click(root)
    await ack()
    await wait(GRACE)
    controller(root).perform("save", { hbt: "forged" })

    expect(hbt()).toEqual([["increment", 0, null]])
  })
})
