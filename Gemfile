# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The core gem
gem "hibiki"

group :development do
  # ReactiveForm is duck-typed (no AR runtime dep), but its contract IS
  # ActiveRecord's — casting, update, errors — so the specs run against a
  # real model on in-memory sqlite. sqlite3 is left unpinned: each Rails
  # version declares its own constraint.
  gem "activerecord"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "rspec-rails", "~> 8.0"
  gem "rubocop", "~> 1.21"
  gem "sqlite3"
end
