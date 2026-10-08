// The focus mark: a field stamped data-hibiki-focus takes focus when a
// render this tab caused inserts it. A mark that was already there, or one a
// render nobody here asked for brings, is left alone.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, flush, receive, sent } from "./support/island.js"

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal("IntersectionObserver", class {
    observe() {}
    unobserve() {}
    disconnect() {}
  })
})

afterEach(async () => {
  await unmount()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

const EDIT = `<button id="edit" data-hibiki-on="click->edit">Edit</button>`
const field = (mark = "true", id = "title") =>
  `<input id="${id}" name="${id}" value="Blue" data-hibiki-focus="${mark}">`
const row = (inner) => `<div id="row">${inner}</div>`

const seqOf = (index = -1) => sent.at(index)[1].hbk
const ack = () => receive({ ack: seqOf() })

// Turbo hands listeners a `render` it will await; the client wraps it.
const streamRender = async (render = () => {}) => {
  const event = new CustomEvent("turbo:before-stream-render", {
    bubbles: true,
    detail: { render }
  })
  document.dispatchEvent(event)
  await event.detail.render()
  await flush()
}

const open = (root, html = field()) => () => { root.querySelector("#row").innerHTML = html }

describe("a render this tab caused", () => {
  it("focuses the marked field it inserts (transmit)", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()

    await receive({ html: row(field()) })
    expect(document.activeElement).toBe(document.querySelector("#title"))
  })

  it("focuses the marked field it inserts (Turbo stream)", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()

    await streamRender(open(root))
    expect(document.activeElement).toBe(root.querySelector("#title"))
  })

  it("selects the text when the mark says so", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()

    await receive({ html: row(field("select")) })
    const input = document.querySelector("#title")
    expect(document.activeElement).toBe(input)
    expect([input.selectionStart, input.selectionEnd]).toEqual([0, 4])
  })

  it("leaves the text unselected otherwise", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()

    await receive({ html: row(field()) })
    const input = document.querySelector("#title")
    expect(input.selectionEnd - input.selectionStart).toBe(0)
  })

  it("focuses an element that was there and gained the mark", async () => {
    const root = await mount(island(`${EDIT}<input id="title">`))
    root.querySelector("#edit").click()

    await streamRender(() => root.querySelector("#title").setAttribute("data-hibiki-focus", "true"))
    expect(document.activeElement).toBe(root.querySelector("#title"))
  })

  it("takes the first of two new marks", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()

    await receive({ html: row(field("true", "title") + field("true", "artist")) })
    expect(document.activeElement).toBe(document.querySelector("#title"))
  })

  it("does not focus again while the marked field stays", async () => {
    const root = await mount(
      island(`${EDIT}${row("")}<input id="other"><button id="more" data-hibiki-on="click->more">More</button>`)
    )
    root.querySelector("#edit").click()
    await streamRender(open(root))
    await ack()

    // A second gesture, answered by a render that keeps the field.
    const other = root.querySelector("#other")
    other.focus()
    root.querySelector("#more").click()
    await streamRender()
    expect(document.activeElement).toBe(other)
  })

  it("leaves focus in a field with unsent input", async () => {
    const root = await mount(
      island(`${row(EDIT)}<input id="q" name="q" data-hibiki-on="input->search" data-hibiki-debounce="250">`)
    )
    root.querySelector("#edit").click()
    const q = root.querySelector("#q")
    q.focus()
    q.value = "ab"
    q.dispatchEvent(new Event("input", { bubbles: true }))

    await streamRender(open(root))
    expect(document.activeElement).toBe(q)
  })
})

describe("the ack and its renders", () => {
  // One action, two broadcasts: the first settles the trip with the ack,
  // and the one carrying the form trails it.
  it("still focuses on a render that trails the ack", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()
    await streamRender()
    await ack()

    await vi.advanceTimersByTimeAsync(300)
    await streamRender(open(root))
    expect(document.activeElement).toBe(root.querySelector("#title"))
  })

  it("stops once the grace has passed", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()
    await streamRender()
    await ack()

    await vi.advanceTimersByTimeAsync(600)
    await streamRender(open(root))
    expect(document.activeElement).not.toBe(root.querySelector("#title"))
  })

  // The motion module holds a render while a leaving element moves, and
  // the ack settles the trip meanwhile.
  it("focuses after a held render, however long the hold", async () => {
    const root = await mount(island(row(EDIT)))
    document.addEventListener("hibiki:before-render", (event) => {
      const render = event.detail.render
      event.detail.render = () => new Promise((resolve) => setTimeout(resolve, 900)).then(render)
    }, { once: true })
    root.querySelector("#edit").click()

    await receive({ html: row(field()) })
    await ack()
    await vi.advanceTimersByTimeAsync(900)
    await flush()
    expect(document.activeElement).toBe(document.querySelector("#title"))
  })
})

describe("a render this tab did not cause", () => {
  it("does not focus the marked field it inserts (transmit)", async () => {
    await mount(island(row(EDIT)))

    await receive({ html: row(field()) })
    expect(document.activeElement).not.toBe(document.querySelector("#title"))
  })

  it("does not focus the marked field it inserts (Turbo stream)", async () => {
    const root = await mount(island(row(EDIT)))

    await streamRender(open(root))
    expect(document.activeElement).not.toBe(root.querySelector("#title"))
  })

  // Seen once, a mark is no longer new: a later gesture does not claim it.
  it("does not focus it on a later render this tab caused", async () => {
    const root = await mount(island(`${EDIT}${row("")}`))
    await streamRender(open(root))

    root.querySelector("#edit").click()
    await streamRender()
    expect(document.activeElement).not.toBe(root.querySelector("#title"))
  })

  it("leaves a mark in the page's first HTML to autofocus", async () => {
    const root = await mount(island(`${EDIT}${field()}`))
    root.querySelector("#edit").click()

    await streamRender()
    expect(document.activeElement).not.toBe(root.querySelector("#title"))
  })

  // A click in the connect window is queued, so a trip is in flight when an
  // unrelated stream renders.
  it("leaves it alone in the connect window too", async () => {
    const root = await mount(island(`${EDIT}${field()}`), { autoConnect: false })
    root.querySelector("#edit").click()

    await streamRender()
    expect(document.activeElement).not.toBe(root.querySelector("#title"))
  })

  it("does not focus on a page refresh morph", async () => {
    const root = await mount(island(row(EDIT)))
    root.querySelector("#edit").click()

    open(root)()
    document.dispatchEvent(new Event("turbo:render"))
    expect(document.activeElement).not.toBe(root.querySelector("#title"))
  })
})

describe("nested islands", () => {
  it("leaves a child island's mark to the child", async () => {
    await mount(
      island(`${EDIT}<div id="child" data-controller="hibiki" data-hibiki-channel-value="ChildChannel"
                         data-hibiki-cid-value="c2"><div id="row"></div></div>`)
    )
    // The click is the parent's gesture; the child has none in flight.
    document.querySelector("#edit").click()

    await streamRender(() => { document.querySelector("#row").innerHTML = field() })
    expect(document.activeElement).not.toBe(document.querySelector("#title"))
  })
})
