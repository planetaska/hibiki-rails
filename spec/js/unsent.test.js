// Unsent input: a debounced field's text is on the page but not yet on the
// server, so a render arriving inside the wait is drawn without it. The
// client records the text at input time and puts it back after the render,
// and flushes pending debounces before any other action so gestures reach
// the server in the order they were made.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, flush, receive, performed, controller } from "./support/island.js"

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

const field = (attrs = "") =>
  `<input id="title" name="title" data-hibiki-on="input->set_field" data-hibiki-debounce="250" ${attrs}>`

const type = (input, text) => {
  input.value = text
  input.dispatchEvent(new Event("input", { bubbles: true }))
}

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

describe("a field with unsent input wins over a render", () => {
  // A morph keeps the element and writes the server's value over it.
  it("puts the typed text back after a morph, and sends it", async () => {
    const root = await mount(island(field()))
    const input = root.querySelector("#title")
    type(input, "abc")

    await streamRender(() => { input.value = "" })
    expect(input.value).toBe("abc")

    await vi.advanceTimersByTimeAsync(250)
    expect(performed).toEqual([["set_field", { title: "abc" }]])
  })

  it("lets the render win once the text has been sent", async () => {
    const root = await mount(island(field()))
    const input = root.querySelector("#title")
    type(input, "abc")
    await vi.advanceTimersByTimeAsync(250)

    await streamRender(() => { input.value = "Abc" })
    expect(input.value).toBe("Abc")
  })

  it("gives the text to the element that replaced the field", async () => {
    const root = await mount(island(`<div id="row">${field()}</div>`))
    type(root.querySelector("#title"), "abc")

    await receive({ html: `<div id="row">${field('value="old"')}</div>` })
    expect(document.querySelector("#title").value).toBe("abc")

    await vi.advanceTimersByTimeAsync(250)
    expect(performed).toEqual([["set_field", { title: "abc" }]])
  })

  it("puts the text back after a page refresh morph", async () => {
    const root = await mount(island(field()))
    const input = root.querySelector("#title")
    type(input, "abc")

    input.value = ""
    document.dispatchEvent(new Event("turbo:render"))
    expect(input.value).toBe("abc")
  })

  it("keeps the caret where the last keystroke left it", async () => {
    const root = await mount(island(field()))
    const input = root.querySelector("#title")
    input.focus()
    input.value = "abcd"
    input.setSelectionRange(2, 2)
    input.dispatchEvent(new Event("input", { bubbles: true }))

    await streamRender(() => { input.value = "" })
    expect(input.value).toBe("abcd")
    expect([input.selectionStart, input.selectionEnd]).toEqual([2, 2])
  })

  // A checkbox's state is not its value.
  it("leaves a debounced checkbox to the render", async () => {
    const root = await mount(
      island(`<input type="checkbox" id="done" name="done" value="1"
                     data-hibiki-on="input->set_field" data-hibiki-debounce="250">`)
    )
    const box = root.querySelector("#done")
    box.checked = true
    box.dispatchEvent(new Event("input", { bubbles: true }))

    expect(controller(root).unsent.size).toBe(0)
  })

  it("drops its records when the island disconnects", async () => {
    const root = await mount(island(field()))
    const instance = controller(root)
    type(root.querySelector("#title"), "abc")
    expect(instance.unsent.size).toBe(1)

    await unmount()
    expect(instance.unsent.size).toBe(0)
  })
})

describe("pending debounces flush before another action", () => {
  it("sends the typed text first, and then lets the render win", async () => {
    const root = await mount(
      island(`${field()}<button data-hibiki-on="click->reset">Reset</button>`)
    )
    const input = root.querySelector("#title")
    type(input, "abc")
    root.querySelector("button").click()

    expect(performed).toEqual([
      ["set_field", { title: "abc" }],
      ["reset", {}]
    ])

    await streamRender(() => { input.value = "" })
    expect(input.value).toBe("")

    await vi.advanceTimersByTimeAsync(250)
    expect(performed).toHaveLength(2)
  })

  // The add form: submit resets the fields at once, so a surviving record
  // would bring the text back with the answering render.
  it("does not bring the text back into a form that submit has reset", async () => {
    const root = await mount(
      island(`<form data-hibiki-on="submit->save">${field()}</form>`)
    )
    const input = root.querySelector("#title")
    type(input, "abc")
    root.querySelector("form").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    expect(performed).toEqual([
      ["set_field", { title: "abc" }],
      ["save", { title: "abc" }]
    ])
    expect(input.value).toBe("")

    await streamRender()
    expect(input.value).toBe("")
  })

  it("flushes nothing when the confirm is declined", async () => {
    vi.stubGlobal("confirm", () => false)
    const root = await mount(
      island(`${field()}<button data-hibiki-on="click->destroy"
                                data-hibiki-confirm="Sure?">Destroy</button>`)
    )
    type(root.querySelector("#title"), "abc")
    root.querySelector("button").click()

    expect(performed).toEqual([])
    await vi.advanceTimersByTimeAsync(250)
    expect(performed).toEqual([["set_field", { title: "abc" }]])
  })
})
