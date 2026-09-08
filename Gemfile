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
  # json 3.0 (2026-09-07) made every option a keyword argument, and Rails
  # 8.1.3.1 still hands JSON.parse a positional hash — have_broadcasted_to
  # blows up in ActiveSupport::JSON.decode. Drop the cap once Rails adapts.
  gem "json", "< 3"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "rspec-rails", "~> 8.0"
  # Pinned to the minor: every RuboCop minor adds cops, and NewCops: enable
  # opts into them — floating would let CI break with no commit here.
  gem "rubocop", "~> 1.90.0"
  gem "sqlite3"
end
