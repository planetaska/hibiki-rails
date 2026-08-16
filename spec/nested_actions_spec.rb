# frozen_string_literal: true

require "rails_helper"
require_relative "support/nested_models"

# Forms for the NestedActions channel spec — real constants because the
# channel classes below name them at build_graph time.
class NestedSpecNoteForm
  include Hibiki::Rails::ReactiveForm

  reactive_attributes Note, :body, :pinned
end

class NestedSpecTaskForm
  include Hibiki::Rails::ReactiveForm

  reactive_attributes Task, :name
  reactive_nested :notes, NestedSpecNoteForm
end

class NestedSpecProjectForm
  include Hibiki::Rails::ReactiveForm

  reactive_attributes Project, :title
  reactive_nested :tasks, NestedSpecTaskForm
end

# The channel under test. The record arrives preloaded through a class
# attribute: the graph actor is its own thread, and a query there would hit
# its own in-memory sqlite connection — actions must stay query-free.
class NestedActionsTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel
  include Hibiki::Rails::NestedActions

  class << self
    attr_accessor :record
  end

  def build_graph
    @editing_id = Hibiki::State.new(nil)
    @form = NestedSpecProjectForm.new
    @creating = Hibiki::State.new(false)
    @new_form = NestedSpecProjectForm.new
  end

  def edit(_data)
    @form.hydrate(self.class.record)
    @editing_id.value = self.class.record.id
  end

  def new_form(_data)
    @new_form.hydrate(Project.new)
    @creating.value = true
  end
end

# A channel holding its form somewhere the default resolver can't see.
class NestedOverrideTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel
  include Hibiki::Rails::NestedActions

  def build_graph
    @custom = NestedSpecProjectForm.from(Project.new)
  end

  private

  def nested_form_for(_dom) = @custom
end

RSpec.describe Hibiki::Rails::NestedActions, type: :channel do
  # FIFO barrier: everything posted before this has run once it returns.
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end

  def form = subscription.instance_variable_get(:@form)
  def create_form = subscription.instance_variable_get(:@new_form)

  def perform(action, **payload)
    subscription.perform_action({ "action" => action.to_s }.merge(payload.transform_keys(&:to_s)))
  end

  describe "as actions" do
    it "exposes exactly the three public methods, internals stay private" do
      expect(NestedActionsTestChannel.action_methods)
        .to include("nested_add", "nested_remove", "nested_set_field")
      expect(NestedActionsTestChannel.action_methods)
        .not_to include("nested_form_for", "__hibiki_nested_target")
    end
  end

  describe "against an open row-edit form" do
    tests NestedActionsTestChannel

    let(:project) { Project.create!(title: "album") }
    let!(:task) { project.tasks.create!(name: "record", position: 1) }
    let(:task_key) { "c#{task.id}" }

    before do
      Note.delete_all
      # Preload the whole tree so hydrate on the graph thread never queries.
      NestedActionsTestChannel.record = Project.includes(tasks: :notes).find(project.id)
      subscribe(cid: "c1")
      perform(:edit)
    end

    it "adds a child at depth one" do
      perform(:nested_add, dom: "project_1", path: "tasks")
      drain
      expect(form.tasks.map(&:nested_key)).to eq([task_key, "n1"])
    end

    it "adds a grandchild at depth two" do
      perform(:nested_add, dom: "project_1", path: "tasks/#{task_key}/notes")
      drain
      expect(form.tasks.sole.notes.sole.nested_key).to eq("n1")
    end

    it "sets a child field, cast through the child's types" do
      perform(:nested_add, dom: "project_1", path: "tasks/#{task_key}/notes")
      perform(:nested_set_field, dom: "project_1", path: "tasks/#{task_key}/notes/n1",
                                 field: "pinned", "tasks/#{task_key}/notes/n1/pinned" => "1")
      drain
      expect(form.tasks.sole.notes.sole.pinned).to be(true)
    end

    it "drops an undeclared field and a missing value key" do
      perform(:nested_set_field, dom: "project_1", path: "tasks/#{task_key}",
                                 field: "position", "tasks/#{task_key}/position" => "9")
      perform(:nested_set_field, dom: "project_1", path: "tasks/#{task_key}", field: "name")
      drain
      expect(form.tasks.sole.name).to eq("record")
    end

    it "removes a new child and marks a persisted one" do
      perform(:nested_add, dom: "project_1", path: "tasks")
      perform(:nested_remove, dom: "project_1", path: "tasks/n1")
      perform(:nested_remove, dom: "project_1", path: "tasks/#{task_key}")
      drain
      expect(form.tasks.map(&:nested_key)).to eq([task_key])
      expect(form.tasks.sole).to be_marked_for_destruction
    end

    it "drops an unknown association, a forged key, and a mis-shaped address" do
      perform(:nested_add, dom: "project_1", path: "bogus")
      perform(:nested_add, dom: "project_1", path: "tasks/#{task_key}")   # child address, not collection
      perform(:nested_remove, dom: "project_1", path: "tasks")            # collection address, not child
      perform(:nested_remove, dom: "project_1", path: "tasks/c999999")
      drain
      expect(form.tasks.map(&:nested_key)).to eq([task_key])
      expect(form.tasks.sole).not_to be_marked_for_destruction
    end
  end

  describe "form routing" do
    tests NestedActionsTestChannel

    before do
      NestedActionsTestChannel.record = Project.includes(tasks: :notes).find(Project.create!(title: "album").id)
      subscribe(cid: "c1")
    end

    it "drops the action when no form is open" do
      perform(:nested_add, dom: "project_1", path: "tasks")
      drain
      expect(form.tasks).to eq([])
    end

    it "routes a _new dom to the inline create form" do
      perform(:new_form)
      perform(:nested_add, dom: "project_new", path: "tasks")
      drain
      expect(create_form.tasks.map(&:nested_key)).to eq(["n1"])
      expect(form.tasks).to eq([])
    end
  end

  describe "with an overridden nested_form_for" do
    tests NestedOverrideTestChannel

    it "resolves through the override" do
      subscribe(cid: "c1")
      perform(:nested_add, dom: "anything", path: "tasks")
      drain
      custom = subscription.instance_variable_get(:@custom)
      expect(custom.tasks.map(&:nested_key)).to eq(["n1"])
    end
  end
end
