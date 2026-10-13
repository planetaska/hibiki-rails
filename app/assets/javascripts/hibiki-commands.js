// hibiki-rails/commands — things a control does in the browser, with no
// round trip: show and hide, classes, attributes, focus, a DOM event, a
// dialog, and a channel action among them.
//
// Opt-in: `import "hibiki-rails/commands"` once, beside the controllers.
// The view declares a list with the `js` helper (`on(js.hide("#panel")
// .push(:cancel))`), which the client finds on the control as
// data-hibiki-do and hands to the interpreter below, in order. Like the
// rest of data-hibiki-*, the list's wire form is private to the gem.
//
// Only the names in OPS run, and an attribute command writes nothing a
// handler, a style or this gem's own wiring could ride in on. Ruby keeps
// the same two lists (Commands::OPS and Commands::REFUSED) and raises at
// render; here anything outside them is skipped. Add a command in both
// places.
//
// What a command changes lasts until the server next renders that element.
// State the server should know belongs in a signal.
import { useCommands } from "hibiki-rails"

const REFUSED = /^(on|style$|srcdoc$|data-hibiki-|data-controller$|data-action$)/i
const ATTRIBUTE = /^[a-z_:][a-z0-9_:.-]*$/i
const ACTION = /^[a-z][a-z0-9_.-]*$/i
const FOCUSABLE =
  'a[href], button:not(:disabled), input:not(:disabled):not([type="hidden"]), ' +
  'select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])'

// A selector is the app's, and a bad one must not stop the rest of a list.
const query = (root, selector, all) => {
  try {
    return all ? [...root.querySelectorAll(selector)] : [root.closest(selector)].filter(Boolean)
  } catch {
    return []
  }
}

// Nothing is the control; a string is looked up in the document; `inner`
// inside the control; `closest` among its ancestors.
const targets = (control, to) => {
  if (to === undefined) return [control]
  if (typeof to === "string") return query(document, to, true)
  if (typeof to?.inner === "string") return query(control, to.inner, true)
  if (typeof to?.closest === "string") return query(control, to.closest, false)
  return []
}

const classes = (names) =>
  Array.isArray(names) ? names.filter((name) => typeof name === "string" && /^\S+$/.test(name)) : []
const writable = (name) => typeof name === "string" && ATTRIBUTE.test(name) && !REFUSED.test(name)

// name -> what it does to one target.
const OPS = {
  show: (element) => element.removeAttribute("hidden"),
  hide: (element) => element.setAttribute("hidden", ""),
  toggle: (element) => element.toggleAttribute("hidden"),
  add_class: (element, { names }) => element.classList.add(...classes(names)),
  remove_class: (element, { names }) => element.classList.remove(...classes(names)),
  toggle_class: (element, { names }) => {
    for (const name of classes(names)) element.classList.toggle(name)
  },
  set_attribute: (element, { name, value }) => {
    if (writable(name)) element.setAttribute(name, String(value ?? ""))
  },
  remove_attribute: (element, { name }) => {
    if (writable(name)) element.removeAttribute(name)
  },
  toggle_attribute: (element, { name, value }) => {
    if (!writable(name)) return
    if (element.hasAttribute(name)) element.removeAttribute(name)
    else element.setAttribute(name, String(value ?? ""))
  },
  dispatch: (element, { name, detail, bubbles }) => {
    if (typeof name !== "string") return
    element.dispatchEvent(new CustomEvent(name, { bubbles: bubbles !== false, detail }))
  },
  show_modal: (element) => {
    if (typeof element.showModal === "function" && !element.open) element.showModal()
  },
  close_dialog: (element) => {
    if (element.open) element.close?.()
  }
}

// Focus goes to one element, so these take the first target only.
const FOCUS = {
  focus: (element) => element,
  focus_first: (element) => element.querySelector(FOCUSABLE)
}

useCommands((ops, control, push) => {
  for (const op of ops) {
    if (!Array.isArray(op)) continue
    const [name, args = {}] = op
    if (name === "push") {
      if (typeof args.action === "string" && ACTION.test(args.action)) push(args.action, args.with ?? {})
    } else if (Object.hasOwn(FOCUS, name)) {
      const [first] = targets(control, args.to)
      if (first) FOCUS[name](first)?.focus()
    } else if (Object.hasOwn(OPS, name)) {
      // With no target, close_dialog closes the dialog the control is in.
      const to = name === "close_dialog" && args.to === undefined ? { closest: "dialog" } : args.to
      for (const element of targets(control, to)) OPS[name](element, args)
    }
  }
})
