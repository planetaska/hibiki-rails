// Render order: Action Cable hands each broadcast to a worker pool, so two
// Turbo streams the channel sent in order can arrive in the other one. The
// channel numbers them and the island applies them by number.
//
// The fault this fixes is a negative one ("the page did not end on the older
// render"), so every example states the arrival order it sets up and reads
// the order the renders ran in.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, controller, disconnectAll, connectAll, flush } from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await vi.advanceTimersByTimeAsync(2000)
  await unmount()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

const GRACE = 100
const FROM = "TestChannel/c1"
const $ = (id) => document.getElementById(id)
const page = island(`<p id="note">first</p><p id="deposit">first</p>`)

let applied

// A <turbo-stream> as Turbo dispatches it, arriving now. `seq: null` is a
// stream the gem did not stamp. The render writes the text into the target,
// as a replace would, and logs it.
const arrive = (seq, target, text = `${target} ${seq}`, from = FROM) => {
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("action", "replace")
  stream.setAttribute("target", target)
  // The properties Turbo's StreamElement has and the motion module reads.
  Object.defineProperties(stream, {
    action: { value: "replace" },
    templateElement: { value: document.createElement("template") },
    targetElements: { get: () => [$(target)] }
  })
  if (seq !== null) {
    stream.setAttribute("data-hibiki-seq", seq)
    stream.setAttribute("data-hibiki-from", from)
  }
  const render = vi.fn(async () => {
    applied.push(text)
    $(target).textContent = text
  })
  const event = new CustomEvent("turbo:before-stream-render", {
    bubbles: true,
    detail: { newStream: stream, render }
  })
  document.dispatchEvent(event)
  return { render, done: event.detail.render(stream) }
}

beforeEach(() => { applied = [] })

describe("renders that arrive in order", () => {
  it("are applied as they come, with nothing waited for", async () => {
    await mount(page)
    arrive(1, "note")
    arrive(2, "note")
    expect(applied).toEqual(["note 1", "note 2"])
    expect(vi.getTimerCount()).toBe(0)
  })
})

describe("renders that arrive out of order", () => {
  // The case found in reverb: actions, actions, deposit sent; deposit,
  // actions, actions transmitted.
  it("are applied in the order sent", async () => {
    const root = await mount(page)
    arrive(3, "deposit")
    expect(applied).toEqual([])

    arrive(1, "note")
    expect(applied).toEqual(["note 1"])
    arrive(2, "note")
    await flush()
    expect(applied).toEqual(["note 1", "note 2", "deposit 3"])
    expect($("note").textContent).toBe("note 2")
    expect(controller(root).renders).toBe(3)
    expect(vi.getTimerCount()).toBe(0)
  })

  it("end on the newer render of one target", async () => {
    await mount(page)
    arrive(2, "note", "newer")
    arrive(1, "note", "older")
    await flush()
    expect(applied).toEqual(["older", "newer"])
    expect($("note").textContent).toBe("newer")
  })

  it("resolve a held render's promise once it has run, as Turbo awaits it", async () => {
    await mount(page)
    const held = arrive(2, "note")
    let settled = false
    held.done.then(() => { settled = true })
    await flush()
    expect(settled).toBe(false)

    arrive(1, "note")
    await flush()
    expect(settled).toBe(true)
  })
})

describe("a render that never arrives", () => {
  it("is given up on after the grace, and the held ones run in order", async () => {
    await mount(page)
    arrive(3, "deposit")
    arrive(2, "note")
    await vi.advanceTimersByTimeAsync(GRACE - 1)
    expect(applied).toEqual([])

    await vi.advanceTimersByTimeAsync(1)
    expect(applied).toEqual(["note 2", "deposit 3"])

    // Past the gap, nothing waits.
    arrive(4, "note")
    expect(applied).toEqual(["note 2", "deposit 3", "note 4"])
  })

  it("gives a second gap its own grace", async () => {
    await mount(page)
    arrive(2, "note")
    arrive(5, "note")
    await vi.advanceTimersByTimeAsync(GRACE)
    expect(applied).toEqual(["note 2"])

    await vi.advanceTimersByTimeAsync(GRACE)
    expect(applied).toEqual(["note 2", "note 5"])
  })
})

describe("a render that arrives after it was given up on", () => {
  it("is dropped when a later render has drawn its target", async () => {
    await mount(page)
    arrive(2, "note", "newer")
    await vi.advanceTimersByTimeAsync(GRACE)

    const late = arrive(1, "note", "older")
    await late.done
    expect(late.render).not.toHaveBeenCalled()
    expect($("note").textContent).toBe("newer")
  })

  it("is drawn when nothing has drawn its target since", async () => {
    await mount(page)
    arrive(2, "note")
    await vi.advanceTimersByTimeAsync(GRACE)

    arrive(1, "deposit")
    expect(applied).toEqual(["note 2", "deposit 1"])
  })

  it("is dropped when it comes twice", async () => {
    await mount(page)
    arrive(1, "note")
    const again = arrive(1, "deposit")
    await again.done
    expect(again.render).not.toHaveBeenCalled()
  })

  it("forgets what was drawn once nothing is missing", async () => {
    const root = await mount(page)
    arrive(2, "note")
    await vi.advanceTimersByTimeAsync(GRACE)
    arrive(1, "deposit")
    arrive(3, "note")
    expect(controller(root).drawn.size).toBe(0)
  })
})

describe("streams that are not this island's", () => {
  it("passes an unstamped stream straight through", async () => {
    await mount(page)
    arrive(2, "note")
    arrive(null, "deposit", "app's own")
    expect(applied).toEqual(["app's own"])
  })

  it("passes another island's stream through, and does not count it", async () => {
    await mount(page)
    arrive(7, "deposit", "theirs", "TestChannel/c2")
    arrive(7, "deposit", "other channel", "OtherChannel/c1")
    arrive(1, "note")
    expect(applied).toEqual(["theirs", "other channel", "note 1"])
  })
})

describe("a reconnect", () => {
  it("applies what was held and counts the fresh graph's renders from 1", async () => {
    await mount(page)
    arrive(1, "note")
    arrive(2, "note")
    arrive(4, "deposit")
    await disconnectAll()
    expect(applied).toEqual(["note 1", "note 2", "deposit 4"])
    expect(vi.getTimerCount()).toBe(0)

    await connectAll()
    arrive(1, "note", "fresh")
    expect(applied.at(-1)).toBe("fresh")
  })

  it("lets go of held renders when the island leaves the page", async () => {
    await mount(page)
    const held = arrive(2, "note")
    document.body.innerHTML = `<p id="note"></p>`
    await flush()
    await held.done
    expect(held.render).toHaveBeenCalledTimes(1)
  })
})

describe("with the motion module", () => {
  const FRAME = 16

  it("does not let a held render be overtaken by a later one", async () => {
    vi.stubGlobal("requestAnimationFrame", (callback) => setTimeout(() => callback(performance.now()), FRAME))
    await import("../../app/assets/javascripts/hibiki-motion.js")
    await mount(island(`<div id="list"><div id="r1" data-motion></div></div><p id="note"></p>`))
    let finish
    $("r1").getAnimations = () => [{ finished: new Promise((resolve) => { finish = resolve }) }]

    // 2 arrives first and waits for 1; 1 removes a marked row, so the motion
    // module holds it for the row's transition.
    arrive(2, "note", "second")
    arrive(1, "list", "first").render.mockImplementation(async () => {
      applied.push("first")
      $("r1").remove()
    })

    await flush()
    await vi.advanceTimersByTimeAsync(FRAME)
    expect($("r1").hasAttribute("data-motion-leaving")).toBe(true)
    expect(applied).toEqual([])

    finish()
    await flush()
    expect(applied).toEqual(["first", "second"])
  })
})
