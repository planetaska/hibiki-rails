// Keys: `keydown.<key>` tokens in data-hibiki-on. Without a scope a key is
// heard while focus is inside the control; with `@window` it is heard
// anywhere on the page while the control is rendered.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, flush, receive, performed } from "./support/island.js"

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

// A cancelable, bubbling keydown, as the browser sends. Returns the event
// so an example can read defaultPrevented.
const press = (target, key, init = {}) => {
  const { keyCode, ...rest } = init
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...rest })
  if (keyCode) Object.defineProperty(event, "keyCode", { value: keyCode })
  target.dispatchEvent(event)
  return event
}

const form = (tokens, inner = `<input id="title" name="title">`, attrs = "") =>
  `<form id="form" data-hibiki-on="${tokens}" ${attrs}>${inner}</form>`

describe("a key inside a control", () => {
  it("performs the action and prevents the key's default", async () => {
    const root = await mount(island(form("keydown.esc->cancel")))
    const event = press(root.querySelector("#title"), "Escape")
    expect(performed).toEqual([["cancel", {}]])
    expect(event.defaultPrevented).toBe(true)
  })

  it("leaves any other key alone", async () => {
    const root = await mount(island(form("keydown.esc->cancel")))
    const event = press(root.querySelector("#title"), "Enter")
    expect(performed).toEqual([])
    expect(event.defaultPrevented).toBe(false)
  })

  it("sends the with: payload and no field value", async () => {
    const root = await mount(
      island(`<input id="title" name="title" value="abc" data-hibiki-on="keydown.enter->pick"
                     data-hibiki-with='{"id":7}'>`)
    )
    press(root.querySelector("#title"), "Enter")
    expect(performed).toEqual([["pick", { id: 7 }]])
  })

  it("knows the named keys, letters and digits", async () => {
    const tokens = "keydown.up->up keydown.space->space keydown.page_down->page keydown.k->k keydown.1->one"
    const root = await mount(island(`<div id="list" tabindex="0" data-hibiki-on="${tokens}"></div>`))
    const list = root.querySelector("#list")
    for (const key of ["ArrowUp", " ", "PageDown", "k", "1"]) press(list, key)
    expect(performed.map(([action]) => action)).toEqual(["up", "space", "page", "k", "one"])
  })

  // The field's own token is the nearest control; the form's still answers.
  it("reaches an ancestor past a control with no key token", async () => {
    const root = await mount(
      island(form("submit->save keydown.esc->cancel",
        `<input id="title" name="title" data-hibiki-on="input->set_field">`))
    )
    press(root.querySelector("#title"), "Escape")
    expect(performed).toEqual([["cancel", {}]])
  })

  it("takes the nearest matching control, once", async () => {
    const root = await mount(
      island(`<div data-hibiki-on="keydown.esc->outer">${form("keydown.esc->inner")}</div>`)
    )
    press(root.querySelector("#title"), "Escape")
    expect(performed).toEqual([["inner", {}]])
  })

  it("is not heard with focus outside the control", async () => {
    const root = await mount(island(`${form("keydown.esc->cancel")}<button id="other"></button>`))
    press(root.querySelector("#other"), "Escape")
    expect(performed).toEqual([])
  })

  it("sends a pending debounced input first", async () => {
    const root = await mount(
      island(form("keydown.enter->pick",
        `<input id="title" name="title" data-hibiki-on="input->set_field" data-hibiki-debounce="250">`))
    )
    const input = root.querySelector("#title")
    input.value = "abc"
    input.dispatchEvent(new Event("input", { bubbles: true }))
    press(input, "Enter")
    expect(performed).toEqual([["set_field", { title: "abc" }], ["pick", {}]])
  })

  it("asks a confirm: first", async () => {
    vi.stubGlobal("confirm", () => false)
    const root = await mount(
      island(form("keydown.esc->cancel", undefined, `data-hibiki-confirm="Discard?"`))
    )
    press(root.querySelector("#title"), "Escape")
    expect(performed).toEqual([])
  })

  it("belongs to its own island when islands nest", async () => {
    const inner = island(form("keydown.esc->inner"), `id="inner"`)
    await mount(island(`<div data-hibiki-on="keydown.esc->outer">${inner}</div>`, `id="outer"`))
    press(document.querySelector("#title"), "Escape")
    expect(performed).toEqual([["inner", {}]])
  })
})

describe("modifiers", () => {
  it("matches a combination", async () => {
    const root = await mount(island(form("keydown.ctrl+s->save")))
    press(root.querySelector("#title"), "s", { ctrlKey: true })
    expect(performed).toEqual([["save", {}]])
  })

  it("matches shift with a letter, whose key is uppercase", async () => {
    const root = await mount(island(form("keydown.meta+shift+k->palette")))
    press(root.querySelector("#title"), "K", { metaKey: true, shiftKey: true })
    expect(performed).toEqual([["palette", {}]])
  })

  it("does not fire a plain key while a modifier is held", async () => {
    const root = await mount(island(form("keydown.s->star")))
    const input = root.querySelector("#title")
    press(input, "s", { ctrlKey: true })
    press(input, "s", { metaKey: true })
    press(input, "S", { shiftKey: true })
    press(input, "s", { altKey: true })
    expect(performed).toEqual([])
  })

  it("does not fire a combination without its modifier", async () => {
    const root = await mount(island(form("keydown.ctrl+s->save")))
    press(root.querySelector("#title"), "s")
    expect(performed).toEqual([])
  })
})

describe("keys that are not gestures", () => {
  // The Enter that ends an IME composition. Safari reports it only as 229.
  it("ignores a key pressed during composition", async () => {
    const root = await mount(island(form("keydown.enter->save")))
    const input = root.querySelector("#title")
    const composing = press(input, "Enter", { isComposing: true })
    const safari = press(input, "Enter", { keyCode: 229 })
    expect(performed).toEqual([])
    expect(composing.defaultPrevented || safari.defaultPrevented).toBe(false)
  })

  it("ignores a held key's repeats", async () => {
    const root = await mount(island(form("keydown.esc->cancel")))
    press(root.querySelector("#title"), "Escape", { repeat: true })
    expect(performed).toEqual([])
  })

  // Chrome's autofill dispatches a keydown with no key.
  it("ignores an event with no key", async () => {
    const root = await mount(island(form("keydown.esc->cancel")))
    root.querySelector("#title").dispatchEvent(new Event("keydown", { bubbles: true }))
    expect(performed).toEqual([])
  })

  it("ignores a key some other handler already took", async () => {
    const root = await mount(island(form("keydown.esc->cancel")))
    const input = root.querySelector("#title")
    input.addEventListener("keydown", (event) => event.preventDefault())
    press(input, "Escape")
    expect(performed).toEqual([])
  })
})

describe("a fallback control", () => {
  it("stands aside until the island is ready", async () => {
    const root = await mount(
      island(form("keydown.enter->save", undefined, `data-hibiki-fallback="true"`)),
      { autoConnect: false }
    )
    const event = press(root.querySelector("#title"), "Enter")
    expect(performed).toEqual([])
    expect(event.defaultPrevented).toBe(false)
  })
})

describe("a window key", () => {
  const hotkey = `<button id="new" data-hibiki-on="click->new_row keydown.n@window->new_row"></button>`

  it("is heard with focus anywhere on the page", async () => {
    await mount(`<p id="elsewhere" tabindex="0"></p>${island(hotkey)}`)
    const event = press(document.querySelector("#elsewhere"), "n")
    expect(performed).toEqual([["new_row", {}]])
    expect(event.defaultPrevented).toBe(true)
  })

  it("fires once with focus inside its own control", async () => {
    const root = await mount(island(hotkey))
    press(root.querySelector("#new"), "n")
    expect(performed).toEqual([["new_row", {}]])
  })

  it("is not a key inside a control", async () => {
    const root = await mount(island(form("keydown.esc->cancel keydown.n@window->new_row")))
    press(root.querySelector("#title"), "n", { ctrlKey: true })
    expect(performed).toEqual([])
  })

  it("can sit on the island root", async () => {
    await mount(island("", `data-hibiki-on="keydown.ctrl+k@window->search"`))
    press(document.body, "k", { ctrlKey: true })
    expect(performed).toEqual([["search", {}]])
  })

  it("takes the first matching control in the island", async () => {
    const row = (id) =>
      `<button data-hibiki-on="keydown.e@window->edit" data-hibiki-with='{"id":${id}}'></button>`
    await mount(island(row(1) + row(2)))
    press(document.body, "e")
    expect(performed).toEqual([["edit", { id: 1 }]])
  })

  it("skips a disabled control and keeps a hidden one", async () => {
    await mount(island(
      `<button disabled data-hibiki-on="keydown.n@window->disabled"></button>
       <span hidden data-hibiki-on="keydown.n@window->hidden"></span>`
    ))
    press(document.body, "n")
    expect(performed).toEqual([["hidden", {}]])
  })

  it("yields to a key a control inside the island answered", async () => {
    const root = await mount(island(
      `${form("keydown.esc->cancel")}<span hidden data-hibiki-on="keydown.esc@window->close"></span>`
    ))
    press(root.querySelector("#title"), "Escape")
    expect(performed).toEqual([["cancel", {}]])
  })

  it("yields to a key the page's own script took", async () => {
    await mount(island(hotkey))
    const taken = (event) => event.preventDefault()
    document.body.addEventListener("keydown", taken)
    press(document.body, "n")
    document.body.removeEventListener("keydown", taken)
    expect(performed).toEqual([])
  })

  it("fires in each island that declares it", async () => {
    await mount(
      island(`<button data-hibiki-on="keydown.n@window->first"></button>`) +
      island(`<button data-hibiki-on="keydown.n@window->second"></button>`, `id="b"`)
    )
    press(document.body, "n")
    expect(performed.map(([action]) => action).sort()).toEqual(["first", "second"])
  })

  it("fires in a later island past one that does not declare it", async () => {
    await mount(
      island(`<button data-hibiki-on="keydown.n@window->first"></button>`) +
      island(`<button data-hibiki-on="keydown.m@window->other"></button>`, `id="b"`) +
      island(`<button data-hibiki-on="keydown.n@window->third"></button>`, `id="c"`)
    )
    press(document.body, "n")
    expect(performed.map(([action]) => action).sort()).toEqual(["first", "third"])
  })

  it("answers for its own controls when islands nest", async () => {
    const inner = island(`<button data-hibiki-on="keydown.n@window->inner"></button>`, `id="inner"`)
    await mount(island(`<button data-hibiki-on="keydown.n@window->outer"></button>${inner}`))
    press(document.body, "n")
    expect(performed.map(([action]) => action).sort()).toEqual(["inner", "outer"])
  })

  describe("while typing", () => {
    const page = (tokens) => island(
      `<input id="q" name="q"><textarea id="notes"></textarea>
       <select id="pick"><option>a</option></select>
       <div id="rich" contenteditable="true"></div>
       <input id="box" type="checkbox">
       <span hidden data-hibiki-on="${tokens}"></span>`
    )

    it("ignores a plain key typed into a field", async () => {
      await mount(page("keydown.n@window->new_row keydown.enter@window->open"))
      for (const id of ["q", "notes", "pick", "rich"]) {
        press(document.getElementById(id), "n")
        press(document.getElementById(id), "Enter")
      }
      expect(performed).toEqual([])
    })

    it("still hears it on a control that takes no text", async () => {
      await mount(page("keydown.n@window->new_row"))
      press(document.getElementById("box"), "n")
      expect(performed).toEqual([["new_row", {}]])
    })

    it("still hears a combination with ctrl or meta", async () => {
      await mount(page("keydown.ctrl+k@window->search keydown.meta+k@window->search"))
      press(document.getElementById("q"), "k", { ctrlKey: true })
      press(document.getElementById("notes"), "k", { metaKey: true })
      expect(performed).toEqual([["search", {}], ["search", {}]])
    })

    it("does not count shift as a way out", async () => {
      await mount(page("keydown.shift+n@window->new_row"))
      press(document.getElementById("q"), "N", { shiftKey: true })
      expect(performed).toEqual([])
    })

    it("still hears Escape", async () => {
      await mount(page("keydown.esc@window->close"))
      press(document.getElementById("q"), "Escape")
      expect(performed).toEqual([["close", {}]])
    })
  })

  describe("the listener", () => {
    const hotkeys = () => {
      press(document.body, "n")
      return performed.length
    }

    it("comes with a control a render adds", async () => {
      await mount(island(`<div id="list"></div>`))
      expect(hotkeys()).toBe(0)
      await receive({ html: `<div id="list">${hotkey}</div>` })
      expect(hotkeys()).toBe(1)
    })

    it("is not on the window for an island with no window key", async () => {
      const added = vi.spyOn(window, "addEventListener")
      await mount(island(form("keydown.esc->cancel")))
      expect(added.mock.calls.filter(([type]) => type === "keydown")).toEqual([])
    })

    it("goes when a render removes the last window key", async () => {
      await mount(island(`<div id="list">${hotkey}</div>`))
      const removed = vi.spyOn(window, "removeEventListener")
      await receive({ html: `<div id="list"></div>` })
      expect(removed.mock.calls.filter(([type]) => type === "keydown").length).toBe(1)
      expect(hotkeys()).toBe(0)
    })

    it("goes when the island disconnects", async () => {
      await mount(island(hotkey))
      const button = document.querySelector("#new")
      document.body.innerHTML = ""
      await flush()
      document.body.append(button)
      expect(hotkeys()).toBe(0)
    })
  })
})
