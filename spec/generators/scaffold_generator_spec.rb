# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"

RSpec.describe Hibiki::Rails::Generators::ScaffoldGenerator do
  include GeneratorHarness

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  def generated(path) = File.read(File.join(@destination, path))
  def migration = Dir[File.join(@destination, "db/migrate/*.rb")].sole

  describe "the headline command" do
    before do
      run_generator(described_class,
                    %w[Widget title:string shelf:references --css=none],
                    destination: @destination)
    end

    it "gets the model, its migration and the route from Rails itself" do
      expect(File.exist?(File.join(@destination, "app/models/widget.rb"))).to be(true)
      expect(File.read(migration)).to include("create_table :widgets")
      expect(generated("config/routes.rb")).to include("resources :widgets")
    end

    it "delegates the controller half to the scaffold_controller generator" do
      expect(File.exist?(File.join(@destination, "app/channels/widgets_channel.rb"))).to be(true)
      expect(File.exist?(File.join(@destination, "app/forms/widget_form.rb"))).to be(true)
      expect(File.exist?(File.join(@destination, "app/views/widgets/_list.html.erb"))).to be(true)
    end

    it "hands attributes down without corrupting them" do
      expect(File.read(migration)).to include("t.string :title")
      expect(File.read(migration)).to include("t.references :shelf, null: false")
    end

    it "forwards its options to the controller generator" do
      expect(generated("app/views/widgets/_widget.html.erb")).not_to match(/class[=:]\s*["']/)
    end
  end

  # Thor replays the parent's raw option set against the child's declarations,
  # so the hand-off needs no code — only the same name and type on both
  # classes. That makes this a test of the DECLARATION, which is the part a
  # future option can forget.
  it "forwards --phlex to the controller generator" do
    run_generator(described_class, %w[Widget title:string --phlex --css=none], destination: @destination)

    expect(File.exist?(File.join(@destination, "app/views/widgets/row.rb"))).to be(true)
    expect(Dir[File.join(@destination, "app/views/**/*.erb")]).to be_empty
  end

  # 14 new .tt files is exactly when a spec.files glob miss bites: the gem
  # builds, installs, and then fails at `bin/rails g` on a template nobody
  # noticed was left out of the package.
  it "ships every scaffold template in the gem" do
    spec = Gem::Specification.load(File.expand_path("../../hibiki_rails.gemspec", __dir__))
    on_disk = Dir[File.expand_path("../../lib/generators/**/templates/**/*.tt", __dir__)]
              .map { it.delete_prefix("#{File.expand_path('../..', __dir__)}/") }

    expect(on_disk).not_to be_empty
    expect(spec.files).to include(*on_disk)
  end

  # THE to_argv regression, and it is 8.x-only because the bang suffix is.
  # GeneratedAttribute#to_s renders `title:string!` as "title:string{null}",
  # which .parse then rejects — so handing attributes down through to_s would
  # drop every required field's null constraint on exactly the versions that
  # support declaring it.
  it "preserves a required field through the hand-off" do
    run_generator(described_class, %w[Widget title:string! --css=none], destination: @destination)

    expect(File.read(migration)).to include("t.string :title, null: false")
  end

  # This command writes the model and then invokes the controller generator in
  # the same process, where the constant is not autoloadable yet. Asking Ruby
  # would answer "there is no Widget" about a file the user just watched
  # scroll past — the migration really is the reason here, and the only path
  # where it is.
  it "blames the migration for a thin live_errors, since here that is the reason" do
    output = run_generator(described_class, %w[Widget title:string --css=none], destination: @destination)

    expect(output).to include("the migration has not run")
    expect(output).not_to include("there is no Widget yet")
  end

  it "refuses without fields, before writing a model or a migration" do
    output = run_generator(described_class, %w[Widget], destination: @destination)

    # Raised in #initialize on purpose: the inherited orm hook runs before any
    # task, so a later check would leave a model and a migration behind for a
    # scaffold that then aborted.
    expect(output).to include("needs at least one field")
    expect(output).to include("hibiki:rails:scaffold_controller Widget")
    expect(Dir[File.join(@destination, "db/migrate/*.rb")]).to be_empty
    expect(File.exist?(File.join(@destination, "app/models/widget.rb"))).to be(false)
  end

  # ResourceGenerator overrides .desc to read usage_path UNCONDITIONALLY, where
  # Base.desc falls back when there is none. Without a shipped USAGE this raises
  # TypeError while `bin/rails g` is merely LISTING generators — breaking every
  # generator in the app, and only from the built gem.
  it "has a USAGE that .desc can read" do
    expect { described_class.desc }.not_to raise_error
    expect(described_class.desc).to include("hibiki:rails:scaffold")
  end

  it "ships that USAGE in the gem" do
    spec = Gem::Specification.load(File.expand_path("../../hibiki_rails.gemspec", __dir__))

    expect(spec.files).to include("lib/generators/hibiki/rails/scaffold/USAGE")
    expect(spec.files).to include("lib/generators/hibiki/rails/scaffold_controller/USAGE")
  end
end
