# frozen_string_literal: true

# The parent/child/grandchild chain reactive_nested's specs run against.
# Project/Task/Note — names collide with nothing in todo_model.rb or
# scaffold_models.rb (the full suite loads every support file into one
# namespace and one schema). Validations sit on the child AND the
# grandchild so error distribution is provable at both depths.

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :projects, force: true do |t|
    t.string :title
  end

  create_table :tasks, force: true do |t|
    t.references :project, null: false
    t.string :name
    t.integer :position
  end

  create_table :notes, force: true do |t|
    t.references :task, null: false
    t.string :body
    t.boolean :pinned, default: false, null: false
  end
end

class Project < ActiveRecord::Base
  has_many :tasks, -> { order(:position) }, dependent: :destroy, inverse_of: :project
  accepts_nested_attributes_for :tasks, allow_destroy: true

  validates :title, presence: true
end

class Task < ActiveRecord::Base
  belongs_to :project
  has_many :notes, dependent: :destroy, inverse_of: :task
  accepts_nested_attributes_for :notes, allow_destroy: true

  validates :name, presence: true
end

class Note < ActiveRecord::Base
  belongs_to :task

  validates :body, presence: true
end
