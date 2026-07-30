# frozen_string_literal: true

# The models the scaffold generators introspect.
#
# ScaffoldSchema has two builders — one reads a parsed `field:type` argument
# list, the other reads a real schema — and only the second needs a database.
# The harness runs the generator in-process, so `destination_root` decides
# where files are WRITTEN while the model constant and its columns come from
# here. That is what makes the introspection path testable without an app
# checkout.
#
# Deliberately a second pair rather than more columns on Todo: Item's
# belongs_to is required, and reactive_form_spec.rb saves bare Todos.
#
# Shaped as a structural isomorph of the reference app's Author/Book
# (~/rails_projects/hibiki-crud) so the generated output can be compared
# against a hand-written conversion that was measured in a browser:
# one belongs_to, one string, one text, one integer with a default, one date,
# one boolean with a default, plus a presence validator and a numericality
# validator. Every derived list the templates need has at least one member and
# at least one non-member.

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :shelves, force: true do |t|
    t.string :name
    t.boolean :active, default: true, null: false
    t.timestamps
  end

  # Column order here is the order `columns_hash` reports, which is what the
  # introspection builder walks — so this file also pins the emitted order of
  # BookRow's members and reactive_attributes' argument list.
  create_table :items, force: true do |t|
    t.integer :shelf_id, null: false
    t.string :title
    t.text :notes
    t.integer :count, default: 0, null: false
    t.date :due_on
    t.boolean :active, default: false, null: false
    t.timestamps
  end
end

class Shelf < ActiveRecord::Base
  has_many :items, dependent: :destroy

  validates :name, presence: true
end

class Item < ActiveRecord::Base
  # Required by default (belongs_to_required_by_default), which is the fact
  # the generated live_errors reads to emit "must be selected".
  belongs_to :shelf

  # The label a belongs_to contributes to the row projection — the generator
  # emits this delegate, so a fixture that lacked it would let a broken
  # template pass.
  delegate :name, to: :shelf, prefix: true, allow_nil: true

  validates :title, presence: true
  validates :notes, presence: true
  validates :count, numericality: { greater_than_or_equal_to: 0 }
end
