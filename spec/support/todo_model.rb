# frozen_string_literal: true

# The record ReactiveForm's specs hydrate from and commit to. Real
# ActiveRecord on the dummy app's in-memory sqlite: the macro's contract is
# AR's own (type_for_attribute casting, update on an unpersisted record,
# errors after a failed save), so a duck-typed fake would only spec itself.

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :todos, force: true do |t|
    t.string :title
    t.boolean :done, default: false, null: false
    t.integer :priority, default: 1, null: false
  end
end

class Todo < ActiveRecord::Base
  validates :title, presence: true
  validates :priority, numericality: { greater_than: 0 }
end
