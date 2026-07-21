# hibiki_rails

Rails glue for [hibiki](https://github.com/planetaska/hibiki):
connection-scoped signal graphs over ActionCable, pushing re-rendered HTML to the page — either through Turbo Streams, or over the channel's own subscription to the gem's packaged client (see [The JS client](https://planetaska.github.io/hibiki/the-js-client/)).

```
cable action arrives → mutate signals → effects render partials →
Turbo Streams broadcast → Turbo morphs the DOM
```

A graph lives per cable connection (in practice: per browser tab), built when the channel subscribes and disposed when it unsubscribes. Effects subscribe to whatever signals they read; when an action writes a signal, exactly the affected effects re-render and broadcast.

Supports Rails >= 7.1, Ruby >= 3.4.

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

### Render the reactive component

The generated components are just Rails partials (or Phlex components, if you used the Phlex generator), so you can render one anywhere like any other partial:

```erb
<%= render "static_pages/counter" %>
```

Congratulations! Now you have your first reactive component!

## Documentation

Documentation site: <https://planetaska.github.io/hibiki/rails-introduction/>

## Development

```
bundle exec rake   # specs + rubocop (same as CI)
```

The spec suite boots a minimal inline Rails app (`spec/support/dummy_app.rb`).

