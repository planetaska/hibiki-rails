# hibiki_rails

Rails integration for [Hibiki](https://github.com/planetaska/hibiki) signals.

Each browser tab gets its own signal graph, held by an Action Cable channel. An action writes a signal, the effects that read it render their partials again, and the new HTML reaches the page through Turbo Streams or the gem's own JS client. Think of it like LiveView but for Rails. You write Ruby, and the page updates.

Requires Rails >= 8.0 and Ruby >= 3.4.

## Installation

```ruby
# Gemfile
gem "hibiki"
gem "hibiki_rails"
```

Then run the install generator:

```sh
bin/rails g hibiki:rails:install
```

Importmap apps are done at this point. Apps with a JS bundler (esbuild, vite, bun, etc.) also need the client from npm:

```sh
npm install hibiki-rails
# or
bun add hibiki-rails
```

## Your first reactive component

```sh
bin/rails g hibiki:rails:stimulus counter static_pages
```

This writes a working counter into `app/views/static_pages`. The component is an ordinary partial, so you can render it anywhere:

```erb
<%= render "static_pages/counter" %>
```

Press `+1` and watch the count update from the server.

## A reactive CRUD resource

The scaffold generators build a resource with a live index (search, filters, sorting, pagination) and edit-in-place rows:

```sh
# A new model, like rails g scaffold
bin/rails g hibiki:rails:scaffold Book title:string author:references

# A model you already have: the schema is read for you
bin/rails g hibiki:rails:scaffold_controller Book

# Phlex components in place of ERB templates
bin/rails g hibiki:rails:scaffold Book title:string --phlex
```

Restart the server after your first scaffold run, so Rails picks up the new `app/forms` and `app/queries` folders.

You can then use the add-on generators to extend a scaffolded resource, like adding a nested resource to the reactive form:

```sh
# Rebuild the form after adding validators to the model
bin/rails g hibiki:rails:form Book

# A dropdown of songs on the album's form, saved through Track
bin/rails g hibiki:rails:multiselect Album Song Track

# Credits nested into the song's form, saved with it in one go
bin/rails g hibiki:rails:nested Song Credit role:string

# A cover image upload on the album's forms
bin/rails g hibiki:rails:upload_field Album cover
```

## Documentation

Full documentation: <https://planetaska.github.io/hibiki/rails-introduction/>

- [Quick start](https://planetaska.github.io/hibiki/rails-quick-start/): installation and a first component
- [Rails usage](https://planetaska.github.io/hibiki/rails-usage/): writing a channel by hand
- [Generators](https://planetaska.github.io/hibiki/generators/): the component shapes
- [CRUD scaffolding](https://planetaska.github.io/hibiki/crud-scaffolding/): the scaffold and its add-ons
- [The JS client](https://planetaska.github.io/hibiki/the-js-client/): the client, loading state, keys and focus

Release notes: [CHANGELOG.md](CHANGELOG.md).

## Development

```sh
bundle install && bun install
bundle exec rake    # Ruby specs + rubocop
bun run test        # the JS client's specs
```

CI runs both. The gem and the npm package share one copy of the client (`app/assets/javascripts/hibiki.js`) and are released together under the same version.

## Contributing

Bug reports and pull requests are welcome at <https://github.com/planetaska/hibiki-rails>. Please keep both suites green, and add a regression spec for any bug fix.

## License

[MIT](LICENSE.txt)
