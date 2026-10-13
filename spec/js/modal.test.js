// The modal mark (Helpers#modal): a <dialog> the server declares open or
// closed is made to match on connect and after each render, its `cancel`
// and `close` reach the graph, and a morph leaves `open` alone.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, performed, receive, flush } from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

const $ = (id) => document.getElementById(id)
const dialog = (open, attrs = "") => `<dialog id="editor" data-hibiki-modal="${open}" ${attrs}><input id="title"></dialog>`
const render = (html) => receive({ html })

describe("the modal mark", () => {
  it("opens a dialog marked open in the page's first HTML", async () => {
    await mount(island(dialog(true)))

    expect($("editor").open).toBe(true)
  })

  it("leaves one marked closed alone", async () => {
    await mount(island(dialog(false)))

    expect($("editor").open).toBe(false)
  })

  it("opens the dialog a render brings, and closes it on the next", async () => {
    await mount(island(`<div id="slot">${dialog(false)}</div>`))
    await render(`<div id="slot">${dialog(true)}</div>`)
    expect($("editor").open).toBe(true)

    await render(`<div id="slot">${dialog(false)}</div>`)
    expect($("editor").open).toBe(false)
  })

  it("closes a dialog that stayed in place when its mark turns", async () => {
    await mount(island(dialog(true)))
    $("editor").dataset.hibikiModal = "false" // what a morph does to it
    document.dispatchEvent(new CustomEvent("turbo:render"))
    await flush()

    expect($("editor").open).toBe(false)
  })

  it("opens again a dialog the visitor closed while the server still says open", async () => {
    await mount(island(`<div id="slot">${dialog(true)}</div><p id="other"></p>`))
    $("editor").close()
    await render(`<p id="other">x</p>`)

    expect($("editor").open).toBe(true)
  })

  it("is not a dialog method on anything else", async () => {
    await mount(island(`<div id="editor" data-hibiki-modal="true"></div>`))

    expect($("editor").hasAttribute("open")).toBe(false)
  })
})

// Giving focus back when a replaced dialog closes is proven in a browser
// (internal-docs/tools/commands_check.mjs): happy-dom lets a field inside a
// closed dialog take focus, which is the very thing that case turns on.
describe("a focus site inside a dialog", () => {
  const editor = (open) => `<div id="slot"><dialog id="editor" data-hibiki-modal="${open}">
    <input id="title" value="Lute" data-hibiki-focus="select"></dialog></div>`
  const page = (open) => island(`<button id="edit" data-hibiki-on="click->edit">Edit</button>${editor(open)}`)

  it("takes focus when this tab's render opens the dialog, though its markup was there", async () => {
    await mount(page(false))
    $("edit").click()
    await render(editor(true))

    expect(document.activeElement).toBe($("title"))
    expect([$("title").selectionStart, $("title").selectionEnd]).toEqual([0, 4])
  })

  it("takes it again each time the dialog opens", async () => {
    await mount(page(false))
    $("edit").click()
    await render(editor(true))
    await render(editor(false))
    $("edit").focus()
    $("edit").click()
    await render(editor(true))

    expect(document.activeElement).toBe($("title"))
  })

  it("is left alone when nobody here asked", async () => {
    await mount(page(false))
    $("edit").focus()
    await render(editor(true))

    expect(document.activeElement).toBe($("edit"))
  })

  it("is the page's own business when the dialog is open in the first HTML", async () => {
    await mount(page(true))
    $("edit").focus()
    $("edit").click()
    await render(`<p id="other"></p>`)

    expect(document.activeElement).toBe($("edit"))
  })
})

describe("a dialog's own events", () => {
  it("cancel reaches the graph, though it does not bubble", async () => {
    await mount(island(dialog(true, 'data-hibiki-on="cancel->cancel"')))
    $("editor").dispatchEvent(new Event("cancel", { cancelable: true }))
    await flush()

    expect(performed).toEqual([["cancel", {}]])
  })

  it("close does too", async () => {
    await mount(island(dialog(true, 'data-hibiki-on="close->closed"')))
    $("editor").dispatchEvent(new Event("close"))
    await flush()

    expect(performed).toEqual([["closed", {}]])
  })

  it("stops listening when the island leaves", async () => {
    await mount(island("") + dialog(false, 'data-hibiki-on="cancel->cancel"'))
    const root = document.querySelector("[data-controller]")
    const orphan = $("editor")
    root.remove()
    await flush()
    document.body.append(root.cloneNode(false))
    orphan.dispatchEvent(new Event("cancel"))
    await flush()

    expect(performed).toEqual([])
  })
})

describe("a morph", () => {
  const morphing = (target, attributeName) => {
    const event = new CustomEvent("turbo:before-morph-attribute", {
      bubbles: true,
      cancelable: true,
      detail: { attributeName, mutationType: "removed" }
    })
    target.dispatchEvent(event)
    return event.defaultPrevented
  }

  it("may not take `open` off a dialog inside an island", async () => {
    await mount(island(dialog(true)))

    expect(morphing($("editor"), "open")).toBe(true)
  })

  it("may change its other attributes", async () => {
    await mount(island(dialog(true)))

    expect(morphing($("editor"), "class")).toBe(false)
  })

  it("is left alone outside an island, and on other elements", async () => {
    await mount(`${island('<details id="d" open></details>')}<dialog id="out" open></dialog>`)

    expect(morphing($("out"), "open")).toBe(false)
    expect(morphing($("d"), "open")).toBe(false)
  })
})
