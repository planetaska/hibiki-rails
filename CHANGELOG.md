# Changelog

The gem and the npm package are released in lockstep and share these version
numbers — `app/assets/javascripts/hibiki.js` is a single copy served both ways,
so importmap and bundler apps always resolve identical client code.

## Unreleased

### Added

**Keys in `on`.** `event:` takes `keydown.<key>`, so a form's Escape or a
list's arrow keys reach the channel with no JavaScript in the app.

```erb
<%= tag.div(**on(:cancel, event: "keydown.esc")) do %> ... <% end %>
<%= link_to "New", new_song_path,
      **on(:new_form, event: ["click", "keydown.n@window"]) %>
```

- A key is heard while focus is inside its element. With `@window` it is
  heard anywhere on the page, for as long as the element is rendered.
- Keys: `enter`, `tab`, `esc`, `space`, `up`, `down`, `left`, `right`,
  `home`, `end`, `page_up`, `page_down`, a letter, or a digit. Modifiers go
  in front: `keydown.ctrl+s`, `keydown.meta+shift+k`. They are `ctrl`, `meta`
  and `shift`, and they match exactly.
- A matched key's default is prevented. Keys pressed during IME composition
  and a held key's repeats are ignored.
- A window key with neither `ctrl` nor `meta` is ignored while the visitor is
  typing in a field, except `esc`.
- A bare `keydown` raises; `input` is the event for typed text.

## 0.16.0 — 2026-10-07

### Added

**`props`: DOM properties from the view.** Some state of a control has no
HTML attribute, so no re-rendered fragment could carry it: a checkbox's
`indeterminate`, a container's scroll position. A page that needed one
brought JavaScript of its own. The new helper writes the wanted properties
beside the element's other attributes, and the client assigns them when the
island connects and after every render, on both transports.

```erb
<%= check_box_tag "all", "1", all_selected,
      **on(:select_all, event: :change)
          .deep_merge(props(indeterminate: some_selected)) %>
<%= tag.div class: "list", **props(scroll_top: 0, key: page) do %>
```

- `indeterminate:` is assigned after every render, so the server's value wins
  over a click (the browser clears the property when the box is clicked).
- `scroll_top:` and `scroll_left:` are assigned to a new element, and again
  only when the helper's output changes, so the visitor's own scrolling
  survives unrelated renders. `key:` takes any JSON value and exists to change
  the output: `scroll_top: 0, key: page` scrolls back to the top on each page
  change, though the `0` never changes.
- The list is an allowlist kept on both sides: an unknown name raises in Ruby
  and is ignored by the client, so a fragment cannot reach `innerHTML` or an
  event handler.
- `props` returns a `{ data: }` hash like `on`. Two splats of the same key do
  not merge, so combine them with `deep_merge` (or Phlex's `mix`).
- The element must be inside an island. This is a client change: the scan that
  re-observes `visible` sentinels after a render now assigns properties in the
  same walk.

Not covered, by design: properties that already have an attribute (`value`,
`checked`, `disabled`, `open` on `<details>`) ride the fragment as before.
Modal dialogs, focus and media playback are method calls, not properties, and
are left for a later release.

### Fixed

- A `visible` sentinel inside a page that a refresh stream
  (`broadcast_refresh_effect`) morphed was not re-observed: the page morph
  runs after the stream's own render returns. The island now also rescans on
  `turbo:render`.

## 0.15.0 — 2026-09-09

### Added

**Motion for generated pages, and the `hibiki-rails/motion` module.** A
re-rendered fragment is merged into the page in place, so a removed element
was gone before the browser could draw it leaving. The new opt-in module
holds a render while a marked element's transitions finish: mark an element
`data-motion` (it needs an id), give it a transition, and `import
"hibiki-rails/motion"` once beside your controllers. The module writes
`data-motion-leaving` on each marked element the incoming fragment lacks,
waits for its transitions, then lets the render run; it brackets an inserted
marked element with `data-motion-entering` so a clip can be scoped to the
motion. `data-motion="own"` animates the leave only when the gesture that
removed the element came from inside it, read from the island's own trip
records. Renders queue in arrival order; a hidden tab waits for nothing;
every wait races a one-second ceiling. Both transports hold. This is a
client change: the four `data-motion*` attributes are public, unlike the
private `data-hibiki-*` ones. Docs: [Motion].

- The scaffold emits it by default under `--css=daisyui` and `tailwind`:
  the inline create card and the row's edit form slide open and shut
  (`hbk-slide` / `hbk-slide-body`), and a row you destroy slides out to the
  left before the list closes the gap (`hbk-slide-x` / `hbk-slide-x-body`,
  marked `own`). The row's display markup gains an id-bearing `contents`
  wrapper, because the merge pairs an anonymous `div` with the edit wrapper
  and rewrites it in place, and `@starting-style` fires only on a real
  insertion; under motion the row's card and card-body are one element, so
  the add-on generators' anchors still hold.
- `app/assets/stylesheets/hibiki_motion.css`, once per app beside the busy
  sheet and wired the same four ways: slide, slide-x, fade, fly, scale and
  blur as Tailwind `@utility` rules (the utilities layer sits above daisyUI's
  components, and a single utility on the element still wins), with duration
  and easing tuned there. Needs Tailwind 4.1. The generator appends
  `import "hibiki-rails/motion"` to `app/javascript/application.js` once
  and prints a `motion` notice when it cannot.
- `--skip-motion` on both scaffold commands leaves every trace out.
  `--css=none` never emits it: the transitions are Tailwind utilities, and
  its output is byte-identical to a `--skip-motion` run.
- Packaging: the engine pins `hibiki-rails/motion`; the npm package exports
  `./motion`. The module imports `"hibiki-rails"` by its bare name, which
  the pin and the package self-reference both resolve.

### Changed

- `hibiki.js` gains three seams for the module: an exported `islandFor(element)`,
  the island's `lastControl` (set in `trackControl`, kept past the trip's
  settle), and a `hibiki:before-render` event dispatched from the island root
  before a transmit swap, with `event.detail.render` replaceable the way
  Turbo's `turbo:before-stream-render` is. `received` returns the render's
  result: `undefined` for a synchronous swap, a promise for a held one. An ack
  settles its trip even while a render is held.
- `CssVariant` gains two tokens, `row_card` and `contents`.

[Motion]: https://planetaska.github.io/hibiki/motion/

## 0.14.0 — 2026-09-07

### Changed

**The infinite-scroll Load-more control has a degraded path.** Under
`--infinite-scroll` the scaffold emitted one button that answered both a
click and the `visible` sentinel event, and gave it no `fallback:` on
purpose: a sentinel that navigates on a dead socket would make scrolling
navigate. Without JavaScript the button rendered and did nothing. The control
is now two elements. The wrapper (`books_load_more`, the same id) is the
sentinel and carries only `visible`. A link inside it is the click path, with
`fallback: true` and a real href: the query already reads `?page=N` as a
growing window, so a degraded click shows every window up to N, and the
link's fragment lands on the last row the reader had already seen. The JS
client is unchanged.

- Both view layers. The Phlex component uses a bare `a`, so no `LinkTo`
  include; `page_url` is now emitted in both pagination modes.
- Regenerating an app changes only `_list.html.erb` / `list.rb`. A system
  test that clicked `#books_load_more button` now clicks the `a`.
- Docs: the fallback contract in [The JS client] gains the rule — never give
  a `visible` control a `fallback:`; split it as the scaffold does.

## 0.13.0 — 2026-09-07

### Changed

**The scaffold's query object lives in `app/queries`.** `hibiki:rails:scaffold`
and `scaffold_controller` write `app/queries/book_query.rb` where they wrote
`app/models/book_query.rb`. The constant is unchanged. `app/queries` is the
directory the query-object gems (ARQO, querifier, query_delegator) already
generate into, so a query one of them writes for the same model meets ours as
a file conflict instead of a second `BookQuery` that Rails loads first. The
move costs no extra restart: the scaffold already creates `app/forms`, and one
restart picks up both.

- Apps scaffolded earlier need nothing. Move the file with `git mv` when
  convenient; `hibiki:rails:multiselect` and `upload_field` find it in either
  place.
- A `--force` re-run writes `app/queries`. Rails autoloads `app/models` first,
  so the post-install output asks you to delete the old file.

## 0.12.0 — 2026-09-06

### Added

**`island` — the ERB block helper for the island root.** One call
generates the cid, stamps the root with `hibiki_island`, and derives the
channel's `turbo_stream_from` inside it:

```erb
<%= island CounterChannel do |cid| %>
  ...
<% end %>
```

- `cid:` defaults to a fresh UUID; the block receives it either way.
- The stream source is derived from the channel class
  (`turbo_stream_from channel.channel_name, cid`), so renaming the channel
  cannot leave a hand-typed streamable behind. `transport: :transmit`
  leaves it out: for a channel that transmits, or one that overrides
  `stream_name` and writes its own line in the block. (`:broadcast` is the
  default; the option is a named value rather than a boolean so it cannot
  be mistaken for Turbo's own `data-turbo="false"`.)
- `params:` passes through; `tag_name:` picks the root element; any other
  keyword lands on it, with a `data:` hash merged beneath the island's own
  keys.
- Class-only (`constantize` a dynamic name at the call site) and ERB-only
  (it needs ActionView's `capture`). Phlex components keep
  `div(**hibiki_island(...))`, which remains the primitive.

Generators are unchanged: their output keeps the explicit three-line form.
No client change; the npm release is the lockstep bump.

## 0.11.0 — 2026-09-05

### Changed

**The client rides turbo-rails' Action Cable consumer.** `hibiki.js` now
takes its consumer from `cable.getConsumer()` (exported by
`@hotwired/turbo-rails`) instead of importing `@rails/actioncable` itself.
Islands and `turbo_stream_from` share ONE websocket where each page used to
open two, an app's `cable.setConsumer(...)` applies to islands too, and the
library stops reaching the page twice: bundler apps shed the second copy
(~14.6 KB; turbo-rails imports `@rails/actioncable/src`, the client imported
the package root, and a bundler cannot dedupe two specifiers), importmap apps
stop fetching `actioncable.esm.js` next to the copy `turbo.min.js` already
carries (~14.8 KB, one request).

- npm: the `@rails/actioncable` peer dependency is gone; `@hotwired/turbo-rails
  >= 8.0` is the peer instead (every Rails 8 app has it).
- `hibiki:rails:install` no longer pins `@rails/actioncable`. An existing pin
  is harmless — nothing imports it — and may be deleted.
- Subscribing now awaits the consumer once (a microtask after the first
  island); nothing observable changes, actions are still queued until the
  subscription confirms.

## 0.10.0 — 2026-08-22

### Added

**`hibiki:rails:upload_field` — a `has_one_attached` upload on both edit
surfaces.** `bin/rails g hibiki:rails:upload_field Album cover` extends a
hibiki:rails scaffold: the classic form gains a direct-upload file field plus
a remove checkbox (a virtual `remove_cover` attribute whose purge yields to a
same-submit upload), and the inline channel form gains a nameless file input
that direct-uploads on change and hands only the signed blob id to the graph.
The pending state lives in the channel (a generated concern under
`app/channels/concerns`, one `include` in the channel), keyed by the form's
dom, so it survives repaints and the edit row and inline create form stay
independent; attach/purge happens after a successful commit. Both channel
queries are preloaded with `with_attached_cover`, `:cover`/`:remove_cover`
join the permitted params, and one shared
`app/javascript/controllers/upload_field_controller.js` is emitted per app —
parameterized by Stimulus values, so a second attachment reuses it. One
attachment per run; `has_one_attached` only.

**`--accept` — non-image formats.** `--accept=pdf,doc` narrows both file
inputs (image by default; tokens `image`, `audio`, `video`, `pdf`, `csv`,
`text`, `doc`, `xls`, `ppt`, plus any raw `type/subtype` or `.ext` passed
through; an unknown token refuses before anything is written). Every display
site — the inline form, the classic form, and the row on the index and show
page — branches per blob at render time on `variable?`: an image gets its
variant thumbnail, anything else its filename and size, with a
`rails_blob_path` link on the row. That is one template for every accept
list, so mixed lists work and a wrong-typed file past the advisory `accept`
no longer breaks the index at `variant`. The image_processing notice fires
only when an image type is accepted. The accept list stays advisory — the
app owns any server-side content-type validation.

**`--many` — `has_many_attached` galleries.** `bin/rails g
hibiki:rails:upload_field Album photos --many` (implied when the model
already declares `has_many_attached :photos`; `--many` against an existing
`has_one_attached` refuses) generates the gallery shape on both surfaces.
The inline form's input takes several files — the shared
`upload_field_controller.js` now uploads one file after another, so a
gallery's pending list keeps the pick order; a single-file input behaves
as before, and a many-mode run refreshes a copy from before the loop. Each
attached file carries a graph-owned ✕ (toggle: ✕ marks, Undo unmarks) and
each pending file its own badge with a ✕ to drop it; the pending state per
form dom is `{ adds:, removes: }`, applied after a successful commit by
APPENDING through `attach` and purging the marked ids — the collection is
never assigned, which since Rails 7.1 replaces it. The classic form gets
the same append/remove split as two virtual model attributes,
`add_photos` (a `multiple` direct-upload field, attached in `before_save`)
and `remove_photo_ids` (a checkbox per attached file, purged in
`after_save`), riding `params.expect` as a braced group. The row and show
page render the gallery with the same per-blob thumbnail-or-filename
branch, so `--many --accept=pdf` is a document list. Two css tokens
(`gallery_item`, `upload_status_list`).

The packaged client did not change — the emitted Stimulus controller imports
`@rails/activestorage` from the app's own dependencies.

## 0.9.1 — 2026-08-18

### Added

**`hibiki:rails:nested` creates a missing child model from the field list.**
`bin/rails g hibiki:rails:nested Song Credit role:string position:integer`
no longer refuses when `Credit` doesn't exist: the generator invokes
`active_record:model` with `song:references` prepended (kept where you put it
if you typed it yourself), then wires the edge off the argument list exactly
as if the field list had narrowed an existing schema. Run
`bin/rails db:migrate` before using the fieldset. A created child is never
ordered silently — put `position` in the field list, or pass
`--position=COLUMN` and the column joins the create-table migration. With an
existing child model nothing changes, and a missing model with no field list
still refuses, now suggesting the inline syntax.

The runtime and the packaged client did not change; the npm 0.9.1 exists only
to keep the lockstep rule.

## 0.9.0 — 2026-08-17

### Added

**`reactive_nested` — nested forms over `accepts_nested_attributes_for`.**
`reactive_nested :credits, "CreditForm"` on a ReactiveForm declares a signal
holding an array of child forms; the child class may itself declare
`reactive_nested`, so depth is composition — nothing counts levels. `#to_h`
serializes the tree as recursive `*_attributes` (with `id:` and `_destroy:`),
so `#commit` persists everything in the record's one save; a failed commit
distributes each child record's errors onto the matching child form, and
`dirty?` tracks child edits, adds, removes, and destroy-marks for free. New
instance API: `nested_add` / `nested_remove` (a persisted child is marked
`_destroy`, a new one leaves the array), `nested_key` (`"c<id>"` / `"n<seq>"`
— stable DOM identity across repaints), `mark_for_destruction`. The form
also unloads its nested associations after every commit attempt: a failed
save leaves AR-built children in the in-memory association, and without the
unload a later success would insert them twice.

**`Hibiki::Rails::NestedActions` — generic channel actions for nested
forms.** Opt-in include next to `Hibiki::Rails::Channel`: `nested_add`,
`nested_remove`, `nested_move` (reorder to an index among visible
siblings — with position stamped from array order, up/down controls are
all a reorderable list needs), and `nested_set_field`, addressing any node by a
`dom` + `path` payload (`"credits/c3/contributions/n1"` — association names
alternating with child keys, any depth). Every hop is gated against the form
classes' declarations, keys against live children, fields against
`hibiki_attributes`. The default form resolver understands the scaffold's
`@form`/`@editing_id` and `@new_form`/`@creating` ivars; override the private
`nested_form_for(dom)` for anything else. No client change — nested controls
name themselves `"#{path}/#{field}"` and ride the existing payload mechanics.

**`hibiki:rails:nested` — generate one parent→child edge of a nested form.**
`bin/rails g hibiki:rails:nested Song Credit`, then `... Credit Contribution`
for the next level — depth is composition, each run wires one edge. The child
model must exist and `belongs_to` the parent; attribute arguments only
reorder or subset what the schema already knows. Emits the child ReactiveForm
and a `_<child>_fields` partial (or Phlex component) with path-addressed
inputs, injects the ordered `has_many` + `accepts_nested_attributes_for`,
`reactive_nested`, the `NestedActions` include, preloads, and the classic
`fields_for` + `params.expect` degraded path into the full-page form. A
`position` column is detected for ordering (`--position=COLUMN` names one,
adding the migration; `--skip-position` opts out) and ordered edges get
up/down controls. Works against a scaffolded collection (root mode) or an
already-nested parent's fields partial (deep mode), on both view layers.

**`perform(action, payload)` is public API — and a `performOn` helper.**
The blessed seam for app JS (a drag library's drop handler, any third-party
widget) to fire actions on an island's graph through the island's OWN
subscription. Reach the controller instance with Stimulus's standard
`application.getControllerForElementAndIdentifier(islandEl, "hibiki")`, or
skip the incantation with the new export — `performOn(element, action,
payload)` finds the island containing `element` and performs through it,
Stimulus context not required. The return value is the contract: truthy (the
trip's sequence number) means the action was accepted — sent live, or queued
during the island's initial connect window — and a repaint is coming, so
leave the DOM as the user arranged it; `undefined` means it was dropped (the
island is offline, the socket turned out to be dead, or no island contains
the element) and the caller owns recovery: revert the gesture, or stand back
and let the next repaint self-heal. Nothing queues across an offline gap, on
purpose — a reconnect builds a fresh server-side graph, and replaying intent
formed against the old one is worse than dropping it. Hand-writing
`data-hibiki-*` attributes and subclassing `ChannelController` to reach an
existing island remain unsupported: the attributes are a private contract,
and a subclass opens a second subscription with a second graph nobody paints
from.

### Fixed

**`perform` during an offline gap reported success while dropping the
payload.** Between a socket drop and the reconnect, `perform` returned the
trip's sequence number as if the action had been accepted, while sending
nothing and queueing nothing. Declared actions never noticed (the fallback
machinery gates on island state before performing), but with the return
value now public API the lie mattered: it returns `undefined` there, the
same dropped signal as a dead socket caught at send.

## 0.8.0 — 2026-08-15

### Added

**`on(..., fallback: true)` — progressive enhancement over native controls.**
A control's native behavior — a link's href, a form's `action=` — is its
degraded path. Only a `ready` island intercepts the gesture and performs the
channel action; while connecting, offline, or stalled the client stands aside
entirely and the browser does what the markup says. A dead-but-undetected
socket is caught too: when the subscription reports the send failed, the
client settles the trip and runs the native behavior by hand
(`form.submit()` / `location.assign`) — the gesture never left, so it cannot
double-fire. Two guarantees ride along: `confirm:` still gates the native
path while scripts run (a destructive submit must not slip past the dialog
just because the island is down), and before any native submit the client
freshens the form's `authenticity_token` from the `csrf-token` meta tag —
forms repainted by a channel are rendered without a session and carry no
token, so freshening is load-bearing, not an edge case. A truly script-free
page still holds its first-paint token and needs no help.

**`transmit_url` — mirror graph state into the address bar.**
`transmit_value`'s URL sibling: an equality-gated effect transmits `{ url: }`
and the client `history.replaceState`s the bar to it. Never `pushState` — the
URL is a mirror of graph state, not a history entry, so there is no popstate
choreography and Back leaves the page normally. Same-origin only; the client
resolves the URL against the page's own origin and refuses anything else.

**The scaffold now generates the whole degraded-path pattern.** The query
object grows a URL half — `from_params` and canonical `url_params` (defaults
omitted) — shared by the controller's first paint, the island's
subscribe-params seeding (the graph starts from the URL's state, so its first
broadcast repaints what the server painted instead of resetting to defaults),
the pagination hrefs, and the channel's `transmit_url`, which also mirrors an
open form's URL so a reload mid-edit lands on the standard edit page. The
controls become one GET form to the index: live, the controls fire channel
actions; dead, Enter, Apply, and the direction button submit natively and
`from_params` answers. Edit is a real link to the edit page, Destroy a real
`button_to` DELETE form, and the page control's links carry real hrefs — all
with `fallback: true`, in both view layers and every css variant.

**The scaffold's list gains an inline create form, on by default.** The New
link (now inside the island) opens a channel-owned create form at the top of
the list — its own `ReactiveForm` instance, so an open row edit and an open
create never fight over state — and degrades to the standard new page. The
shared row form is parameterized (`dom:`, `save_action:`, `cancel_action:`,
`field_action:`, `cancel_with:`) and serves both uses; `--skip-create` omits
the whole surface. Generated forms also gate live validation on `dirty?`, so
a freshly opened form paints clean instead of flagging every blank field.

**`hibiki:rails:multiselect` serves the inline create form too.** The
dropdown appears with the full option list and an empty selection; each
checkbox's toggle names the form it belongs to, so an open row edit and the
create form never cross-write, even side by side.

### Changed

**Re-running the scaffold over a pre-0.8.0 app refreshes a same-styled shared
page control in place** — the regenerated list passes the new `url:` local,
which the old shared partial does not declare. A page control written under a
different `--css` style is still kept and noticed, never restyled.

## 0.7.0 — 2026-08-12

### Added

**`hibiki:rails:multiselect` — a dropdown multi-select over a
`has_many :through`, layered onto a scaffolded resource.**

```
bin/rails g hibiki:rails:multiselect Album Song Track
```

Owner and target must exist and be migrated; the join model is generated when
missing (a `belongs_to` pair with `touch:` on the owner side — a join write IS
an owner change — and a unique index over the pair) and named off the owner's
reflection when the `has_many :through` is already declared, where the third
argument may be omitted. An existing join gets `touch: true` added to its
`belongs_to`.

The channel half is a generated concern (`AlbumsChannel::SongsMultiselect`
under `app/channels/concerns/`) that wraps `build_graph`, `list_locals` and
`edit` with `super` via a prepended module — one `include` line is the
channel's only edit, and the concern's public `toggle_song` / `search_songs`
methods are client-invocable actions like any other. The form object gains
`reactive_association :songs`.

The selection is owned by the graph, not the form markup: each checkbox sends
its own toggle carrying its checked state (a set, so two tabs converge), and
the submit payload never carries the ids. That is what keeps the built-in
searchable filter honest — narrowing the option list can never drop
selections it hides. Options are capped (`--limit`, default 50) with a
LIMIT+1 fetch whose extra row becomes the "type to narrow" hint — no COUNT
per keystroke. `--skip-search` drops the filter AND the cap, which would
strand the options it hides. `--label` overrides the inferred display column;
`--phlex` and `--css` are detected from what the scaffold left behind.

**A multiple `<select>`'s full selection now reaches the channel, and
`ReactiveForm` can carry a collection's ids.** Two halves shipped together:
the client collects every FormData entry of a `[]`-suffixed field name as an
array under the bare key (previously last-wins, so a multi-select submitted
only one option; non-`[]` duplicate keys stay last-wins on purpose — the
hidden-field checkbox convention depends on it), and
`reactive_association :tags` on a `ReactiveForm` defines a `tag_ids` signal
that hydrates from the record's ids reader and commits through the
association writer, casting each id via the target model's primary-key type.

**`hibiki:rails:form` — re-derive a resource's form from its validators.**
`bin/rails g hibiki:rails:form Book` reads the migrated schema and rewrites the
validator-shaped files only: the `ReactiveForm` (its `live_errors` clauses) and
the two form views (number-field bounds, requiredness). Everything else the
scaffold wrote is untouched, and Thor still asks per file before replacing
edits. `--skip-views` limits it to the form object; the view layer and css
variant are detected from the files a previous run left, with `--phlex` and
`--css` as overrides. An optional field list chooses order and subset, never
facts.

### Changed

**Scaffolded partials pass a generic `extras: {}` hash down the
list → row → row form chain, in both view layers.** The extension point
add-on generators ride: merge locals into the broadcast under one key and
they arrive at the row form with no partial edits. Existing scaffolds keep
working untouched — a generator that needs the hash on pre-0.7.0 output
threads it in with a `compat` notice.

**The scaffold's empty-`live_errors` notice now recommends
`bin/rails g hibiki:rails:form Book`** — on its own line, with no retyped field
list — instead of re-running `scaffold_controller` with the full arguments. The
migration the scaffold wrote preserves the argument order, so once it has run
the schema answers both order and facts.

## 0.6.0 — 2026-08-10

### Added

**`Hibiki::Rails.record_equals` — a per-signal comparator for ActiveRecord
records.** `ActiveRecord#==` compares class and id only, so a stale record is
`==` to its edited reload and a signal write carrying the fresh one is silently
dropped. Pass the comparator per signal and the write goes through:

```ruby
state(:items, equals: Hibiki::Rails.record_equals) { fetch }
```

It compares class + `attributes`, recurses through arrays, and falls back to
`==` for everything else. It needs hibiki 0.3.0's `equals:` (see the dependency
change below), which is honored at both of the graph's equality gates — the
write gate and the flush-time check — so a change that passes the comparator
actually reaches the page. This is opt-in sugar that makes the snapshot pattern
forgiving; "records stop at the boundary" stays the documented default, and a
comparator still cannot see an in-place mutation that never enters the write
path.

**A development-mode warning for the write that pattern swallows.** When a
`State` write is dropped by the default `==` but the old and new values'
`attributes` differ — the classic silent-stale-UI debugging session — the log
now says so and points at the docs. Development only (never test or
production), zero semantic change: the write is still dropped.

### Changed

**The scaffold's row projection is gone — records now cross the boundary as
frozen snapshots.** `app/models/book_row.rb` is no longer generated. The query
object's `rows` returns real records, hardened at the boundary —

```ruby
def rows
  @rows ||= window_scope.strict_loading.map { it.readonly!; it.freeze }
end
```

— and the channels' `rows`/`row` deriveds compare them with
`equals: Hibiki::Rails.record_equals`. What the `Data` projection's structural
`==` used to provide, the comparator provides; what it could never provide, the
freeze triple does: an attribute write raises `FrozenError`, `save` raises
`ActiveRecord::ReadOnlyRecord`, and an unpreloaded association walk raises
`ActiveRecord::StrictLoadingViolationError` instead of firing a lazy query off
the graph thread. Views print a `belongs_to` label as `book.author&.name`
directly, so **the scaffold no longer injects a `delegate` per `belongs_to`
into the model** — the model injection is the `after_commit` ping alone. The
member channel's fetch preloads its associations (`includes(...) +
strict_loading`) for the same reason.

Existing scaffolded apps keep working untouched: their `book_row.rb` and
delegates are app code, and the runtime reads none of it. Re-running a scaffold
with `--force` moves the resource over; the generator never deletes, so the
orphaned `*_row.rb` stays on disk for you to remove.

**The hibiki dependency floor is `~> 0.3`** (per-signal `equals:`, shipped in
hibiki 0.3.0). Everything 0.2 provided still holds; generated channels now rely
on the comparator being consulted at both equality gates.

**The page control and the field-error line are shared partials now.** Each
scaffold used to write its own copy per resource; both are presentation-only,
so they are emitted once per app instead — `app/views/shared/_pagination.html.erb`
and `_field_error.html.erb` (under `--phlex`: `Views::Shared::Pagination` and
`Views::Shared::FieldError` in `app/views/shared/`). Everything resource-shaped
reaches the page control as locals from the list partial. A second scaffold
finds the files present and leaves them; if they were generated under a
different `--css` style, a notice says so instead of silently restyling every
other resource's control.

**Pagination renders above the list as well as below**, so a long page starts
with a control in reach. Both copies live inside the re-rendered fragment and
carry distinct ids (`books_pagination_top` / `books_pagination`), so idiomorph
updates them in place.

Re-running a scaffold with `--force` moves the list over to the shared
partials and prints a notice naming the now-dead per-resource copies — the
generator never deletes them itself.

**The form's error summary is a shared partial too** —
`app/views/shared/_form_errors.html.erb` (under `--phlex`:
`Views::Shared::FormErrors`), rendered by every scaffolded full-page form. The
resource name comes off the record at render time, so one file serves every
scaffold. Under `--css=tailwind` and `--css=daisyui` the block is styled as a
red alert panel instead of the scaffold-stock `style="color: red"`, which
`--css=none` keeps.

### Fixed

**The `hibiki_busy.css` import lands directly below `@import "tailwindcss";`**
instead of at the end of the entry stylesheet — appending placed it after
`@plugin` lines, and CSS requires every `@import` before any other statement.
Also fixed: re-running a scaffold in a tailwindcss-rails app
(`app/assets/tailwind/application.css`) duplicated the import on every run,
because the idempotence probe checked the wrong path spelling.

## 0.5.1 — 2026-08-08

### Changed

**Generator output and messages slimmed down.** The scaffold templates used to
carry long design-rationale comments into every generated file; they are now
one-to-three-line hints, with the docs holding the prose. The safety notes a
user editing the file actually needs stayed: public channel methods are
client-invocable actions, ActionCable's exact-arity rule, the untrusted
subscribe param, Phlex omitting `false`-valued attributes, and the busy
stylesheet's do-not-wrap-in-a-layer rule.

The generators' status notices were shortened the same way — they still say
what to do, just not why at essay length.

No behavior change anywhere: no code inside any template moved, and neither
the runtime nor the packaged client changed (the npm 0.5.1 exists only to keep
the lockstep rule). Re-running a scaffold with `--force` rewrites the views
with the shorter comments; that diff is the whole upgrade.

## 0.5.0 — 2026-08-05

### Added

**`--phlex` on both scaffold generators.** `bin/rails g hibiki:rails:scaffold
Book title:string --phlex` emits Phlex components under `app/views/books/*.rb`,
namespaced `Views::`, instead of ERB templates. Purely additive: without the
flag nothing about the generated output changes, byte for byte.

Only the view layer moves. The channels, the query object, the ReactiveForm,
the model injections, every action and the whole `data-hibiki-*` protocol are
the same either way — the controller gains an explicit `render Views::…` at
each of its six render sites, and the two `broadcast_morph` calls swap
`partial:`/`locals:` for `renderable:`, and that is the entire difference
outside the templates.

Needs `phlex-rails` and `bin/rails g phlex:install`. The generator warns when
either is missing and writes the files anyway, so the scaffold can come first.

Four things worth knowing, because they are not what an ERB reader expects.
Phlex renders `String`, `Symbol`, `Integer` and `Float` and raises on anything
else, so date, time and decimal columns are emitted with an explicit `to_s`.
Phlex omits a `false`-valued attribute entirely, so the page control's
`data-turbo` is the string `"false"`. Phlex emits no whitespace between
siblings, so the components space their inline neighbours explicitly. And
`options_for_select` outputs directly and raises if its return value is passed
on, so both select sites take their options from a block.

The page control is still the one component with a per-`--css` fork, in both
trees. Under Phlex the plain-Tailwind fork's *reason* dissolves — a hoisted
template local becomes an ordinary constant — but it stays forked so the two
trees match file for file and a future `--css` decision stays a diff rather
than a judgement call.

### Changed

**The loading and connection recipes are an asset, not a partial.** They were a
103-line inline `<style>` emitted as `app/views/<resource>/_busy.html.erb` and
rendered once per page; they are now
`app/assets/stylesheets/hibiki_busy.css`, written once per app.

Per resource was always wrong: every rule keys on an attribute the client
stamps and none of them mentions a model, so a two-resource app carried two
byte-identical copies. It also put CSS somewhere a Content-Security-Policy that
forbids inline styles would reject.

The generator wires it for you: a cssbundling or tailwindcss-rails entry
stylesheet gets an `@import`, a layout already using
`stylesheet_link_tag :app` or `:all` needs nothing, and anything else gets a
`stylesheet_link_tag` injected into the layout. Only when none of those applies
does it print the line to add. Every branch is idempotent.

**If you re-run the generator on an app scaffolded before this**, the old
`_busy.html.erb` stays on disk — a generator never deletes — and nothing
renders it any more. The post-install output names it; delete it.

The rules are deliberately unlayered, and the file says so: two of them set
`display` on elements that also carry Tailwind utilities, and unlayered
declarations beat `@layer utilities` whatever the link order.

### Fixed

**The npm package no longer drags in a second copy of `@rails/actioncable`.**
It moves from `dependencies` to `peerDependencies` at `>= 7.0`, matching
turbo-rails' own range.

Why there were two: `@rails/actioncable`'s npm `latest` dist-tag is 7.2.302 even
though 8.x is published, and resolvers prefer `latest` when it satisfies the
range. So turbo-rails' `>=7.0` took 7.2.302 while this package's `>= 8.0` was
forced up to 8.1.301, and both ended up in the bundle — about 16 KB of duplicate
client, and two separate module instances that could never share a consumer.
A fresh install happened to hoist a single copy; the duplicate appeared when
adding hibiki-rails to an app whose lockfile already pinned 7.2.302, which is
every existing app.

If your bundler warns about an unmet peer, install `@rails/actioncable`
explicitly — but a stock Rails app already has it via turbo-rails, and both bun
and npm 7+ auto-install a missing peer. The client uses only `createConsumer`,
`subscriptions.create` and `subscription.perform`, all stable since Action
Cable 6, so the lower floor changes nothing at runtime.

### Changed — BREAKING

**The Rails floor is now 8.0.** `actioncable` and `railties` move from
`>= 7.1` to `>= 8.0`, and the 7.1 / 7.2 CI legs are gone. Ruby stays at `>= 3.4`.

This is a correction as much as a policy change: **generated controllers never
ran on Rails 7.** `hibiki:rails:scaffold` emits `params.expect` at two sites,
inherited from Rails 8's own scaffold, and `ActionController::Parameters#expect`
does not exist before 8.0 — so a generated controller raised `NoMethodError` on
the first request to `show`, `edit`, `update`, `create` or `destroy` on 7.1 and
7.2. The generator suite never caught it because those specs assert on emitted
source text and never boot the result.

The alternative — branching the template on `Rails::VERSION` — was rejected: it
would also need a way to *execute* generated output on the old legs, which is
more work than dropping two CI legs for a version combination (Rails 7.x on
Ruby >= 3.4) that barely exists.

**If you are on Rails 7.1 or 7.2, stay on 0.4.0.** It remains available and is
unaffected; nothing in 0.5.0 is a security fix for it. Note that the *runtime*
half of the gem — channels, the graph, the broadcast helpers, the client — has
no known 8.0-only dependency; it is the generators whose output does. The floor
applies to the whole gem anyway, because shipping a gem whose headline generator
cannot run on its own declared floor is what got us here.

## 0.4.0 — 2026-08-03

### Added

**Loading and connection state, stamped by the client.** The first growth of the
`data-hibiki-*` protocol since 0.3.0, and the first attributes in it that no Ruby
helper emits — the client writes them at runtime and app CSS reads them:

```
island root      data-hibiki-busy      present while an action is in flight
                 aria-busy="true"      the same fact, for assistive tech
                 data-hibiki-state     connecting | ready | offline | stalled
firing control   data-hibiki-busy      on the control that started it
```

Everything an app wants out of that is a descendant selector —
`[data-hibiki-busy] .spinner { display: inline-block }` — so per-row and
per-button feedback needs no server state and no `{#if loading}` branch. The
Ruby surface is unchanged: no new option on `on`, `hibiki_island` or `reactive`.

**Actions are acknowledged once their batch has run**, and the ack is what clears
the indicator. It cannot be "clear on the next render": the core's equality gate
(hibiki 0.2.0) lets an ordinary action produce zero bytes — paging to the page
you are already on, a search that does not change the query, a destroy of a row
another tab already deleted — so a render-based rule hangs forever on gestures
users make all the time. The ack sits in an `ensure`, so a raising action stops
the spinner too, and a subscription that has gone away acks `dropped: true` from
the cable thread instead, which is what lets the client tell "late" from "never".

A page running the 0.3.0 client sends no sequence number and gets no ack, so
nothing about this reaches an app that has not upgraded both halves.

**Actions performed before the subscription confirms are queued, not dropped.**
ActionCable's `Subscription#perform` silently returns false on a socket that is
not open yet, and on the Turbo-broadcast path that window is about three
serialised round trips — a click in it used to vanish. The queue covers the first
connect window only: after a reconnect the server rebuilds the graph with default
state, so replaying intent formed against the old one is worse than dropping it,
and the island reads `offline` for the whole gap instead.

Three class properties on `ChannelController` are the entire tuning surface —
`busyDelay` (150 ms before a trip is worth mentioning), `busyGrace` (60 ms for a
broadcast still in flight after its ack), `busyCeiling` (10 s before a trip is
declared stalled rather than cleared silently). Deliberately not Stimulus values
and not helper options; an app that wants different numbers subclasses and
re-registers.

The scaffold generators wire five sites to all of this — the counts line, the
pagination bar, the infinite-scroll sentinel, the destroy button and the
inline-edit Save — through a generated `_busy.html.erb` the app owns.

**`hibiki:rails:scaffold` and `hibiki:rails:scaffold_controller`** — a reactive
CRUD resource generated the way `rails g scaffold` generates a plain one.

```sh
bin/rails g hibiki:rails:scaffold Book title:string author:references
bin/rails g hibiki:rails:scaffold_controller Book   # an existing model
```

The generated index is live: search, filter, sort and pagination are signal
state rather than page loads, rows edit in place, and a write from anywhere —
another tab, another user, the plain controller, a console — repaints every open
list. Everything is derived from the model's schema (columns, types, `belongs_to`
reflections, validators) or from the same `NAME field:type` argument list Rails'
own scaffold takes.

Stock `rails g scaffold` is untouched; these live under their own namespace.

Live per-field validation is derived only from rules the form can actually
evaluate before a round trip: presence, length, and numericality bounds that
carry no `allow_nil:`/`allow_blank:` exemption for the value in hand. A
validator gated on `if:`, `unless:` or `on:` depends on the record rather than
the field, so it contributes nothing live — it still runs at commit and still
lands in `#errors`, which the same per-field slots mirror. The clauses are
generated once; add validators and re-run `scaffold_controller` to pick them up.

**Field order is yours, and choosing it costs nothing.** With no field list the
columns follow the schema, which for an app built from `schema.rb` means
alphabetical. Passing them explicitly picks the order — and against a model that
already exists the generator still reads that model for everything else, so the
live clauses, a number field's `min:`/`max:` and a `belongs_to`'s display label
all survive the choice:

```sh
bin/rails g hibiki:rails:scaffold_controller Author name:string bio:text age:integer
```

A field the model has no column for is still generated, from the argument list
alone, and named in the post-install output — it may be a column whose migration
is still to come, and a silently missing field is the worse failure.

**A unique index with no uniqueness validator is called out.** A database
constraint is not a validator, and the generated form can only mirror what the
model checks — so without one, a duplicate raises `ActiveRecord::RecordNotUnique`
on the graph thread instead of showing a field error, and the round trip
completes having saved nothing. The generator names the column and the exact
`validates` line, for single and composite indexes alike.

Options: `--css=daisyui|tailwind|none` (detected when absent),
`--infinite-scroll`, `--skip-pagination`, `--skip-search`, `--page-size=N`,
`--skip-routes`.

Three notes on what it does to an app you already have.

**The model is modified** — one `delegate` per `belongs_to`, plus the
`after_commit` broadcast the whole thing hangs off.

**So is each model a `belongs_to` points at.** It gains the `has_many` half
Rails' own scaffold never writes (without it the generated destroy button raises
`InvalidForeignKey`) and a ping of its own, because a row prints the parent's
label rather than its id — rename an author and every open books index would
otherwise keep the old name. `dependent:` follows the association: `:destroy`
when it is required, `:nullify` when it is `optional: true`. That ping is
collection-grained, so an open *show* page keeps the old label until reload.

Both injections are idempotent and announced, and anything you already declared
is left alone — including a `dependent:` you chose yourself.

And **restart the server afterwards**: `app/forms/` is likely new, and Rails
computes autoload paths from the `app/*` glob at boot.

### Fixed

**The model injection missed every namespaced model.** Thor anchors
`inject_into_class` on the class name as the file spells it, and the generator
passed the demodulized one — so `app/models/admin/book.rb`, which Rails writes as
`class Admin::Book < ApplicationRecord`, never matched. Silently: Thor rewrote
the file byte-identical and the generator reported a modification. The delegate
never landed, so the show page raised on arrival.

## 0.3.0 — 2026-07-28

### Security

**Channel lifecycle methods were client-invocable on Rails 7.1 and 7.2.**
Upgrade if you run hibiki_rails on either. Rails 8.x apps were never affected.

ActionCable builds a channel's client-invocable actions from the public methods
the class adds. The gem subtracted its lifecycle hooks through ActionCable's
`internal_methods` hook — but **that hook only exists on Rails 8.x**; on 7.1 and
7.2 `action_methods` never consults it, so the override was silently inert and
the hooks stayed exposed.

Reachable by any client that can open a subscription, against its own
connection's graph. There is no cross-connection or cross-user data exposure;
the impact is resource exhaustion:

- `perform("build_graph")` — exposed on **every** affected app, since
  `#build_graph` is always public. It re-runs the graph build outside
  `Hibiki.root`, so the effects it creates are unowned and the dispose on
  unsubscribe never reaches them, while the previous root is still held. Each
  call leaks; repeated calls grow memory without bound.
- `perform("subscribed")` — exposed only where an app defined `#subscribed`
  public, which the ActiveRecord guide's own `after_commit` example did until
  this release. It allocates a second `GraphActor` — a new **thread** — and
  overwrites the reference to the first, so the original is never stopped.
  Repeated calls exhaust the process's threads.

Fixed by subtracting in `action_methods` itself, which works on every supported
version:

```ruby
HIDDEN_ACTIONS = %w[build_graph subscribed unsubscribed].freeze
def action_methods = super - HIDDEN_ACTIONS
```

No application change is required. Writing `#subscribed` and `#unsubscribed`
private is still the better habit, because it also protects the methods this
list does not know about — the guides now show them that way.

### Added

- `on(action, event:)` takes an **event list**, so one element can answer
  several events: `on(:load_more, event: %i[click visible])`.
- **`input`** joins the delegated events, with a per-control **`debounce:`**.
  `:input` carries 250 ms unless told otherwise (`debounce: 0` opts out); the
  value is stamped into the markup rather than being an invisible client
  default.
- **`visible`**, a pseudo-event backed by an `IntersectionObserver`, so a
  load-more control can double as an infinite-scroll sentinel. It fires once
  per observation and re-attaches to the replacement element after each
  fragment swap.
- **`confirm:`** on `on(...)` — a `window.confirm` gate. `data-turbo-confirm`
  does nothing on a hibiki control, since it is not a Turbo-driven form.
- **`reset: false`** on a submit, to keep a form's inputs. The default resets
  them synchronously, before the server has replied, which is right for an
  "add" form and destroys an edit form's contents on a failed commit.
- **Subscribe params**: `hibiki_island(channel, cid:, params: { record_id: })`
  reach the channel as `params[:key]`, which is how a channel learns which
  record its page is about. They are client-supplied and untrusted — use one
  only to look up a record inside a scope the channel chooses, and never
  interpolate one into a streamable name. They cannot override `channel` or
  `cid`.
- The client has its own test suite (`spec/js`, vitest + happy-dom) and a CI
  job, plus a pinned Rails 8.1 matrix leg.

### Changed

- **A changed checkbox now sends its checked state as a boolean**, and a
  multi-select sends an array of its selected values. Previously both sent
  `control.value` — the value *attribute* — so checking and unchecking a
  checkbox produced byte-identical payloads. **This is a payload shape
  change**: an action reading a `change` payload for a checkbox now receives
  `true`/`false` rather than `"1"`. The form-submit path is unaffected.
- `transmit_value` is **equality-gated**: an effect re-runs whenever any signal
  it read changed, so a bumped version token used to re-send every reactive
  value's text even when byte-identical. The block still runs unconditionally,
  so dependency collection is unchanged — only the transmit is skipped. If you
  render a reactive placeholder *inside* a broadcast-replaced fragment, render
  it with its current value: the swap resets the DOM text and the gate now
  suppresses the re-send that used to heal it.
- Each graph job runs inside `Rails.application.executor`, so
  `CurrentAttributes` are reset between jobs, autoloads are safe off the main
  thread, and each job gets its own query cache.
- Graph-thread errors are **logged** in development and test.
  `ActiveSupport::ErrorReporter` has no subscribers by default, so in a stock
  app these previously vanished entirely — no line, no stack, just a fragment
  that stopped updating. Production behaviour is unchanged.

## 0.2.0 — 2026-07-21

- Reactive values: `reactive` / `reactive_attrs` / `transmit_value`, matched
  document-wide so a value can render outside the island that computes it.
- `Components::` namespacing for the Phlex generator.

## 0.1.0 — 2026-07-18

Initial release.
