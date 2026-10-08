// Focus return: when a render removes the element that had focus, the
// client puts focus on the nearest thing that survived, so a keyboard user
// keeps their place and the island's keys are still heard.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, flush, receive } from "./support/island.js"

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

const SHOW = `<button id="show" data-hibiki-on="click->edit">Quest</button>`
const FORM = `<form><input id="name" name="name" value="Blue"><button>Save</button></form>`
const list = (rowInner, extra = "") =>
  `<div id="list">${extra}<div id="row">${rowInner}</div></div>`

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

const active = () => document.activeElement

describe("a render that removes the focused element", () => {
  it("focuses the first control of its nearest id-bearing ancestor", async () => {
    const root = await mount(island(list(FORM)))
    root.querySelector("form button").focus()

    await streamRender(() => { root.querySelector("#row").innerHTML = `<span>Blue</span>${SHOW}` })
    expect(active()).toBe(root.querySelector("#show"))
  })

  it("skips controls that cannot take focus", async () => {
    const root = await mount(island(list(FORM)))
    root.querySelector("#name").focus()

    await streamRender(() => {
      root.querySelector("#row").innerHTML =
        `<input type="hidden" name="h"><button disabled>Off</button>${SHOW}`
    })
    expect(active()).toBe(root.querySelector("#show"))
  })

  // Only controls take focus: a container never does.
  it("leaves focus alone when that ancestor holds no control", async () => {
    const root = await mount(island(list(FORM)))
    root.querySelector("#name").focus()

    await streamRender(() => { root.querySelector("#row").innerHTML = `<span>Blue</span>` })
    expect(root.contains(active())).toBe(false)
    expect(root.querySelector("#row").hasAttribute("tabindex")).toBe(false)
  })

  // A destroyed row: the list's first control would be the top row's.
  it("leaves focus alone when only an ancestor further up survived", async () => {
    const root = await mount(island(list(FORM, `<button id="top">Top</button>`)))
    root.querySelector("#name").focus()

    await streamRender(() => root.querySelector("#row").remove())
    expect(root.contains(active())).toBe(false)
    expect(root.querySelector("#list").hasAttribute("tabindex")).toBe(false)
  })

  it("leaves focus alone when no ancestor has an id", async () => {
    const root = await mount(island(`<div class="row">${FORM}</div><button id="top">Top</button>`))
    root.querySelector("form button").focus()

    await streamRender(() => root.querySelector(".row").remove())
    expect(root.contains(active())).toBe(false)
  })

  it("applies to a render this tab did not cause, over transmit too", async () => {
    await mount(island(list(FORM)))
    document.querySelector("form button").focus()

    await receive({ html: list(SHOW) })
    expect(active()).toBe(document.querySelector("#show"))
  })

  // The motion module holds a render while the leaving form moves.
  it("waits out a held render", async () => {
    await mount(island(list(FORM)))
    document.addEventListener("hibiki:before-render", (event) => {
      const render = event.detail.render
      event.detail.render = () => new Promise((resolve) => setTimeout(resolve, 900)).then(render)
    }, { once: true })
    document.querySelector("form button").focus()

    await receive({ html: list(SHOW) })
    await vi.advanceTimersByTimeAsync(900)
    await flush()
    expect(active()).toBe(document.querySelector("#show"))
  })

  it("follows a page refresh morph", async () => {
    const root = await mount(island(list(FORM)))
    root.querySelector("form button").focus()

    document.dispatchEvent(new Event("turbo:before-render"))
    root.querySelector("#row").innerHTML = SHOW
    document.dispatchEvent(new Event("turbo:render"))
    expect(active()).toBe(root.querySelector("#show"))
  })
})

describe("a replaced element with the same id", () => {
  it("takes the focus its predecessor had, and the caret", async () => {
    await mount(island(list(FORM)))
    const input = document.querySelector("#name")
    input.focus()
    input.setSelectionRange(2, 3)

    await receive({ html: list(FORM) })
    const next = document.querySelector("#name")
    expect(next).not.toBe(input)
    expect(active()).toBe(next)
    expect([next.selectionStart, next.selectionEnd]).toEqual([2, 3])
  })
})

// The control whose gesture opened a focus site is where focus goes when
// that site closes: the invoker, as a dialog returns to its button.
describe("the control that opened a focus site", () => {
  const MARKED = `<form><input id="name" name="name" data-hibiki-focus="true"><button>Save</button></form>`
  const NEW = `<button data-hibiki-on="click->new_form">New</button>`
  const edit = (id) =>
    `<a href="/e" data-hibiki-on="click->edit" data-hibiki-with='{"id":${id}}'>Edit</a>`
  const click = (control) =>
    control.dispatchEvent(new Event("click", { bubbles: true, cancelable: true }))

  it("takes focus back when it stayed on the page", async () => {
    const root = await mount(island(`${NEW}<div id="list"><button id="top">Top</button><div id="slot"></div></div>`))
    const opener = root.querySelector("button")
    opener.click()
    await streamRender(() => { root.querySelector("#slot").innerHTML = `<div id="card">${MARKED}</div>` })
    expect(active()).toBe(root.querySelector("#name"))

    await streamRender(() => root.querySelector("#card").remove())
    expect(active()).toBe(opener)
  })

  // The Edit link is replaced by the form and written again when it closes.
  it("is found again by its action and payload", async () => {
    const root = await mount(island(
      `<div id="list"><div id="a">${edit(1)}</div><div id="row"><input type="checkbox" id="flag">${edit(2)}</div></div>`
    ))
    click(root.querySelector("#row a"))
    await streamRender(() => { root.querySelector("#row").innerHTML = MARKED })

    await streamRender(() => {
      root.querySelector("#row").innerHTML = `<input type="checkbox" id="flag">${edit(2)}`
    })
    expect(active()).toBe(root.querySelector("#row a"))
  })

  it("is found again by its id", async () => {
    const show = `<button id="show" data-hibiki-on="click->edit">Quest</button>`
    await mount(island(list(`<span>x</span>${show}`)))
    document.querySelector("#show").click()
    await receive({ html: list(MARKED) })

    await receive({ html: list(`<button id="other">Other</button>${show}`) })
    expect(active()).toBe(document.querySelector("#show"))
  })

  it("is remembered across renders that replace the site", async () => {
    await mount(island(`${NEW}${list("")}`))
    const opener = document.querySelector("button")
    opener.click()
    await receive({ html: list(MARKED) })
    await receive({ html: list(MARKED) })

    await receive({ html: list("") })
    expect(active()).toBe(opener)
  })

  it("falls to the row's first control when it is gone for good", async () => {
    const root = await mount(island(list(edit(2))))
    click(root.querySelector("#row a"))
    await streamRender(() => { root.querySelector("#row").innerHTML = MARKED })

    await streamRender(() => { root.querySelector("#row").innerHTML = `<button id="first">First</button>` })
    expect(active()).toBe(root.querySelector("#first"))
  })
})

describe("focus that needs no return", () => {
  it("leaves focus where the visitor put it during the render", async () => {
    const root = await mount(island(`${list(FORM)}<input id="q">`))
    root.querySelector("#name").focus()

    await streamRender(() => {
      root.querySelector("#q").focus()
      root.querySelector("#row").innerHTML = SHOW
    })
    expect(active()).toBe(root.querySelector("#q"))
  })

  it("does nothing when the focused element survives", async () => {
    const root = await mount(island(list(FORM, `<button id="top">Top</button>`)))
    const input = root.querySelector("#name")
    input.focus()

    await streamRender(() => root.querySelector("#top").remove())
    expect(active()).toBe(input)
  })

  it("does nothing when focus was outside the island", async () => {
    const root = await mount(`<input id="out">${island(list(FORM))}`)
    document.querySelector("#out").focus()

    await streamRender(() => { root.querySelector("#row").innerHTML = SHOW })
    expect(active()).toBe(document.querySelector("#out"))
  })

  it("yields to a focus mark the same render brings", async () => {
    const root = await mount(island(list(`${SHOW}`)))
    const show = root.querySelector("#show")
    show.focus()
    show.click()

    await streamRender(() => {
      root.querySelector("#row").innerHTML =
        `<button id="first">First</button><input id="name" data-hibiki-focus="true">`
    })
    expect(active()).toBe(root.querySelector("#name"))
  })

  it("leaves a nested island's focus to that island", async () => {
    await mount(
      island(`<div id="outer"><button id="top">Top</button>
                <div id="child" data-controller="hibiki" data-hibiki-channel-value="ChildChannel"
                     data-hibiki-cid-value="c2"><div id="row">${FORM}</div></div></div>`)
    )
    document.querySelector("#name").focus()

    await streamRender(() => { document.querySelector("#row").innerHTML = SHOW })
    expect(active()).toBe(document.querySelector("#show"))
  })
})
