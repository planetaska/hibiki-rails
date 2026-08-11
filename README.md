# hibiki_rails

Rails glue for [hibiki](https://github.com/planetaska/hibiki):
connection-scoped signal graphs over ActionCable, pushing re-rendered HTML to the page — either through Turbo Streams, or over the channel's own subscription to the gem's packaged client (see [The JS client](https://planetaska.github.io/hibiki/the-js-client/)).

```
cable action arrives → mutate signals → effects render partials →
Turbo Streams broadcast → Turbo morphs the DOM
```

A graph lives per cable connection (in practice: per browser tab), built when the channel subscribes and disposed when it unsubscribes. Effects subscribe to whatever signals they read; when an action writes a signal, exactly the affected effects re-render and broadcast.

Supports Rails >= 8.0, Ruby >= 3.4.

## Rails quick start

### Installation

**Step 1** - Install the gem (`hibiki_rails` depends on the core `hibiki` gem)

```ruby
# Gemfile
gem "hibiki"
gem "hibiki_rails"
```

Or `gem install hibiki hibiki_rails`.

**Step 2** - Run the install generator

```sh
bin/rails g hibiki:rails:install
```

The install generator detects whether your app uses an import map:

- For importmap apps, installation is fully automatic — you are done.
- For apps with a JS bundler (esbuild, vite, bun, ...), also install the companion JS client (published as an npm package) with **one of**:
  - `npm install hibiki-rails`
  - `yarn add hibiki-rails`
  - `bun add hibiki-rails`
  - or the equivalent for your setup

### Using the generator

You can create reactive components easily with the provided generators.

Create your first reactive component by running:

```sh
# Replace [your_view_path] with your desired view path,
# e.g. counters, posts, users/profile...
bin/rails g hibiki:rails:stimulus counter [your_view_path]

# For example, this creates "counter" component partials
# inside app/views/static_pages
bin/rails g hibiki:rails:stimulus counter static_pages
```

This creates a minimal working reactive component in the given view path.

### Generating a whole CRUD resource

For a full reactive resource — a live index with search, filtering, sorting and
pagination, plus edit-in-place — use the scaffold generators:

```sh
# Model, migration, route and the reactive resource, like rails g scaffold
bin/rails g hibiki:rails:scaffold Book title:string author:references

# Or, for a model you already have — the schema is read for you
bin/rails g hibiki:rails:scaffold_controller Book

# Same, but you pick the field order; everything else still comes from the model
bin/rails g hibiki:rails:scaffold_controller Book title:string author:references

# After adding validators: re-derive the form and its views, touching nothing else
bin/rails g hibiki:rails:form Book
```

Your plain `rails g scaffold` is untouched. The generated markup is styled to
match your app (DaisyUI, Tailwind, or unstyled — detected automatically, or
forced with `--css=`). Run `bin/rails g hibiki:rails:scaffold --help` for the
rest of the options.

Pass `--phlex` for Phlex components under `app/views/books/*.rb` instead of ERB
templates. It needs `phlex-rails` and `bin/rails g phlex:install`, and it
changes the view layer only — the channels, the query object, the form and the
whole client protocol are the same either way. Note this is a different thing
from the `hibiki_phlex` gem, which makes a component own reactive state; here
the channel owns the state and the components are ordinary stateless views.

Listing the fields yourself only chooses their order and which ones appear — the
model still answers everything else, so the live validation, a number field's
`min:`/`max:` and a `belongs_to`'s display label all survive the choice.

Because the live validation is derived from the model's validators, a scaffold
generated before its migration ran starts with none. `hibiki:rails:form` is the
catch-up: it rewrites only the `ReactiveForm` and the two form views from the
schema as it stands now, asks before replacing anything you edited, and takes
`--skip-views` to rewrite the form object alone.

Your models are edited, not just read: the one being scaffolded gains the
`after_commit` broadcast that makes writes from anywhere reach an open list, and
each model a `belongs_to` points at gains the `has_many` half plus a ping of its
own, so renaming a parent repaints the lists that print its name. Both are
idempotent, announced, and leave anything you already declared alone.

One file lands outside the resource: `app/assets/stylesheets/hibiki_busy.css`,
which styles the loading and connection state the client stamps. It is written
once per app, shared by every generated resource, and wired into your stylesheet
or layout automatically — the post-install output says which, or gives you the
line to add when it cannot tell.

Restart the server afterwards: `app/forms/` is new, and Rails works out its
autoload paths at boot.

### Render the reactive component

The generated components are just Rails partials (or Phlex components, if you used the Phlex generator), so you can render one anywhere like any other partial:

```erb
<%= render "static_pages/counter" %>
```

Congratulations! Now you have your first reactive component!

## Documentation

Documentation site: <https://planetaska.github.io/hibiki/rails-introduction/>

Release notes and upgrade advice: [CHANGELOG.md](CHANGELOG.md). **Rails 7.1 and 7.2 are supported up to 0.4.0 only** — 0.5.0 raises the floor to 8.0. If you are staying on 0.4.0 with Rails 7.x, read the 0.3.0 entry: it fixes channel lifecycle methods that were client-invocable on those versions.

## Development

```
bundle exec rake   # Ruby specs + rubocop
bun install && bun run test   # the client's own specs
```

Both are what CI runs. The Ruby suite boots a minimal inline Rails app (`spec/support/dummy_app.rb`); the JS suite (`spec/js/`) drives the real Stimulus controller in happy-dom against a stubbed Action Cable consumer.

The gem and the npm package are **released in lockstep**: `app/assets/javascripts/hibiki.js` is the single copy — the engine puts it on the asset path and `package.json` points `main`/`module`/`exports` at it — so importmap and bundler apps must never be able to resolve different client code. Bump `lib/hibiki/rails/version.rb` and `package.json` in the same commit, and publish both. The version table lives in [the JS client docs](https://planetaska.github.io/hibiki/the-js-client/).

## Contributing

Bug reports and pull requests are welcome at <https://github.com/planetaska/hibiki-rails>.

A few things that make a change easier to accept:

- **`bundle exec rake` and `bun run test` both green.** They are what CI runs, and the client half is easy to forget — most changes here touch one side, but the wire protocol is shared by both.
- **A regression spec first** for anything that was a bug. `spec/js/` covers the client, `spec/generators/` the generated output.
- **Generated code follows `rubocop-rails-omakase`**, which is what a stock Rails app lints with — not this gem's own style. The templates are written to satisfy the app's linter, not ours.
- **The `data-hibiki-*` attributes are a private contract** between the Ruby helpers and the vendored JS, and the two halves ship in one version — so a change to either side belongs in one commit with the other. Two of them, `data-hibiki-busy` and `data-hibiki-state`, are written by the client rather than by a helper, and apps select on them from CSS; those need a CHANGELOG entry even when no Ruby changes.

### Running against a checkout

The gem side needs nothing special: point an app's Gemfile at your clone with `gem "hibiki_rails", path: "../hibiki-rails"`.

The npm side has one trap. `bun link` from an app resolves the linked package's own imports from the **symlink's realpath**, not from the app — so `hibiki.js` looks for `@rails/actioncable` inside your checkout rather than inside the app that linked it, and if the checkout has no `node_modules` the import fails at build time with nothing pointing at the cause.

```sh
cd hibiki-rails && bun install   # before linking, not after
```

This affects only development against a clone. Anyone installing the published package resolves normally and never sees it.

## License

[MIT](LICENSE.txt)
