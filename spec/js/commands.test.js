// hibiki-rails/commands: a control whose token names `*` runs the list in
// data-hibiki-do in the browser, in order, a channel action among it.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, performed, sent, receive, flush } from "./support/island.js"

beforeEach(async () => {
  vi.useFakeTimers()
  await import("../../app/assets/javascripts/hibiki-commands.js")
})
afterEach(async () => {
  await unmount()
  vi.restoreAllMocks()
  vi.useRealTimers()
})

const $ = (id) => document.getElementById(id)
const button = (ops, attrs = "") =>
  `<button id="go" data-hibiki-on="click->*" data-hibiki-do='${JSON.stringify(ops)}' ${attrs}>Go</button>`
const page = (ops, rest = "", attrs = "") => island(`${button(ops, attrs)}${rest}`)
const click = async () => {
  $("go").click()
  await flush()
}

describe("show, hide and toggle", () => {
  it("write the hidden attribute", async () => {
    await mount(page([["hide", { to: "#a" }], ["show", { to: "#b" }], ["toggle", { to: "#c" }]],
      `<p id="a"></p><p id="b" hidden></p><p id="c"></p>`))
    await click()

    expect([$("a").hidden, $("b").hidden, $("c").hidden]).toEqual([true, false, true])
  })

  it("act on the control when given no target", async () => {
    await mount(page([["hide", {}]]))
    await click()

    expect($("go").hidden).toBe(true)
  })

  it("performs nothing", async () => {
    await mount(page([["hide", {}]]))
    await click()

    expect(performed).toEqual([])
  })
})

describe("targets", () => {
  it("reaches every match in the document, outside the island too", async () => {
    await mount(`${page([["add_class", { names: ["on"], to: ".item" }]], `<i class="item" id="in"></i>`)}
      <i class="item" id="out"></i>`)
    await click()

    expect([$("in").className, $("out").className]).toEqual(["item on", "item on"])
  })

  it("looks inside the control", async () => {
    await mount(island(`<button id="go" data-hibiki-on="click->*"
      data-hibiki-do='[["hide",{"to":{"inner":"b"}}]]'><b id="mine"></b></button><b id="other"></b>`))
    await click()

    expect([$("mine").hidden, $("other").hidden]).toEqual([true, false])
  })

  it("looks up from the control", async () => {
    await mount(island(`<ul><li id="row">${button([["add_class", { names: ["open"], to: { closest: "li" } }]])}</li>
      <li id="next"></li></ul>`))
    await click()

    expect([$("row").className, $("next").className]).toEqual(["open", ""])
  })

  it("skips a selector the browser refuses, and runs the rest", async () => {
    await mount(page([["hide", { to: "p[" }], ["hide", { to: "#a" }]], `<p id="a"></p>`))
    await click()

    expect($("a").hidden).toBe(true)
  })
})

describe("classes and attributes", () => {
  it("add, remove and toggle classes", async () => {
    await mount(page([["add_class", { names: ["a", "b"], to: "#t" }], ["remove_class", { names: ["x"], to: "#t" }],
      ["toggle_class", { names: ["y", "z"], to: "#t" }]], `<p id="t" class="x y"></p>`))
    await click()

    expect($("t").className).toBe("a b z")
  })

  it("set, remove and toggle attributes", async () => {
    await mount(page([["set_attribute", { name: "aria-expanded", value: "true", to: "#t" }],
      ["remove_attribute", { name: "title", to: "#t" }], ["toggle_attribute", { name: "open", value: "", to: "#t" }],
      ["toggle_attribute", { name: "lang", value: "en", to: "#t" }]], `<details id="t" title="x" lang="fr"></details>`))
    await click()

    const t = $("t")
    expect(t.getAttribute("aria-expanded")).toBe("true")
    expect(t.hasAttribute("title")).toBe(false)
    expect(t.hasAttribute("open")).toBe(true)
    expect(t.hasAttribute("lang")).toBe(false)
  })

  it.each(["onclick", "ONLOAD", "style", "srcdoc", "data-hibiki-on", "data-controller", "data-action", "a b"])(
    "write nothing to %s",
    async (name) => {
      await mount(page([["set_attribute", { name, value: "x", to: "#t" }], ["toggle_attribute", { name, to: "#t" }]],
        `<p id="t"></p>`))
      await click()

      expect($("t").attributes.length).toBe(1)
    }
  )
})

describe("focus", () => {
  it("goes to the target", async () => {
    await mount(page([["focus", { to: "#name" }]], `<input id="name">`))
    await click()

    expect(document.activeElement).toBe($("name"))
  })

  it("goes to the first control inside the target", async () => {
    await mount(page([["focus_first", { to: "#panel" }]],
      `<div id="panel"><span></span><input type="hidden"><input id="first"><input id="second"></div>`))
    await click()

    expect(document.activeElement).toBe($("first"))
  })
})

describe("dispatch", () => {
  it("fires a bubbling CustomEvent with its detail", async () => {
    await mount(page([["dispatch", { name: "cart:opened", detail: { id: 3 }, to: "#t" }]], `<p id="t"></p>`))
    const heard = vi.fn()
    document.addEventListener("cart:opened", (event) => heard(event.target.id, event.detail))
    await click()

    expect(heard).toHaveBeenCalledWith("t", { id: 3 })
  })

  it("stays on the target when told not to bubble", async () => {
    await mount(page([["dispatch", { name: "ping", bubbles: false, to: "#t" }]], `<p id="t"></p>`))
    const heard = vi.fn()
    document.addEventListener("ping", heard)
    await click()

    expect(heard).not.toHaveBeenCalled()
  })
})

describe("push", () => {
  it("performs the action with its own payload, among the other commands", async () => {
    await mount(page([["hide", { to: "#panel" }], ["push", { action: "cancel", with: { id: 7 } }]], `<p id="panel"></p>`))
    await click()

    expect($("panel").hidden).toBe(true)
    expect(performed).toEqual([["cancel", { id: 7 }]])
  })

  it("is the control's own trip: busy until the ack", async () => {
    await mount(page([["push", { action: "save" }]]))
    await click()
    await vi.advanceTimersByTimeAsync(150)
    expect($("go").hasAttribute("data-hibiki-busy")).toBe(true)

    await receive({ ack: sent.at(-1)[1].hbk })
    await vi.advanceTimersByTimeAsync(60)
    expect($("go").hasAttribute("data-hibiki-busy")).toBe(false)
  })

  it("adds a submitted form's fields", async () => {
    await mount(island(`<form id="f" data-hibiki-on="submit->*" data-hibiki-reset="false"
      data-hibiki-do='[["push",{"action":"save","with":{"id":1}}]]'><input name="title" value="Hi"></form>`))
    $("f").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    await flush()

    expect(performed).toEqual([["save", { id: 1, title: "Hi" }]])
  })

  it("refuses an action name that is not one", async () => {
    await mount(page([["push", { action: "a->b" }], ["push", {}]]))
    await click()

    expect(performed).toEqual([])
  })
})

describe("a list", () => {
  it("prevents the event's default", async () => {
    await mount(island(`<a id="go" href="/elsewhere" data-hibiki-on="click->*" data-hibiki-do='[["hide",{}]]'>x</a>`))
    const event = new MouseEvent("click", { bubbles: true, cancelable: true })
    $("go").dispatchEvent(event)

    expect(event.defaultPrevented).toBe(true)
  })

  it("skips a command it does not know", async () => {
    await mount(page([["eval", { code: "x" }], "hide", ["innerHTML", {}], ["hide", { to: "#a" }]], `<p id="a"></p>`))
    await click()

    expect($("a").hidden).toBe(true)
  })

  it("does nothing when the attribute is not a list", async () => {
    await mount(island(`<button id="go" data-hibiki-on="click->*" data-hibiki-do='{"hide":1}'>x</button>
      <button id="bad" data-hibiki-on="click->*" data-hibiki-do='[['>x</button>`))
    await click()
    $("bad").click()
    await flush()

    expect($("go").hidden).toBe(false)
  })

  it("runs nothing when the confirm is declined", async () => {
    window.confirm = vi.fn(() => false)
    await mount(page([["hide", {}], ["push", { action: "go" }]], "", 'data-hibiki-confirm="Sure?"'))
    await click()

    expect($("go").hidden).toBe(false)
    expect(performed).toEqual([])
    delete window.confirm
  })

  it("waits out a debounce as one", async () => {
    await mount(page([["hide", { to: "#a" }]], `<p id="a"></p>`, 'data-hibiki-debounce="200"'))
    await click()
    expect($("a").hidden).toBe(false)

    await vi.advanceTimersByTimeAsync(200)
    expect($("a").hidden).toBe(true)
  })

  it("answers a key too", async () => {
    await mount(island(`<div id="go" tabindex="0" data-hibiki-on="keydown.esc->*" data-hibiki-do='[["hide",{}]]'></div>`))
    $("go").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }))
    await flush()

    expect($("go").hidden).toBe(true)
  })
})

describe("dialogs", () => {
  it("opens one modally and closes it", async () => {
    await mount(page([["show_modal", { to: "#d" }]],
      `<dialog id="d"><button id="x" data-hibiki-on="click->*" data-hibiki-do='[["close_dialog",{}]]'>x</button></dialog>`))
    await click()
    expect($("d").open).toBe(true)

    $("x").click()
    await flush()
    expect($("d").open).toBe(false)
  })

  it("leaves an open dialog open, and a closed one closed", async () => {
    await mount(page([["show_modal", { to: "#d" }], ["show_modal", { to: "#d" }], ["close_dialog", { to: "#e" }]],
      `<dialog id="d"></dialog><dialog id="e"></dialog>`))
    await click()

    expect([$("d").open, $("e").open]).toEqual([true, false])
  })
})
