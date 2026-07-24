# frozen_string_literal: true

# Minimal in-process Rails app for channel specs — combustion-style, but
# inline and transparent so the harness has no extra dependency. Only what
# the gem touches is loaded: no asset pipeline. ActiveRecord is here for
# ReactiveForm's specs (see support/todo_model.rb) — the gem itself stays
# AR-free, duck-typing the record.
#
# Deliberately NOT spike/: wiring the spike as the spec dummy would couple
# the gem's CI to the spike's Gemfile, and the spike does not travel when
# hibiki_rails is extracted to its own repo.

# DATABASE_URL instead of a config/database.yml: the dummy app has no
# config directory on disk, and Rails' database_configuration accepts the
# URL in place of the file on every version in the CI matrix. The schema
# is code too (support/todo_model.rb), so nothing on disk describes the
# database.
ENV["DATABASE_URL"] ||= "sqlite3::memory:"

require "rails"
require "action_controller/railtie"
require "action_cable/engine"
require "active_record/railtie"
require "turbo-rails"

class DummyApp < Rails::Application
  config.root = File.expand_path("dummy_root", __dir__)
  # Track the bundled Rails so the CI matrix (gemfiles/) exercises each
  # version's own defaults.
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = false
  config.logger = ActiveSupport::Logger.new(IO::NULL)
  config.secret_key_base = "hibiki-rails-dummy"
  # have_broadcasted_to reads back from the test pubsub adapter.
  config.action_cable.cable = { "adapter" => "test" }
end

Rails.application.initialize!

# Turbo::Streams::Broadcasts#render_format renders broadcast partials
# through ApplicationController — the dummy app points it at the specs'
# view directory.
class ApplicationController < ActionController::Base
  append_view_path File.expand_path("views", __dir__)
end
