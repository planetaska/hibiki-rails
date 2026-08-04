# frozen_string_literal: true

require "rails/generators"
require "erubi"

# The generators are found by Rails via $LOAD_PATH at runtime; specs load
# them all up front the same way a `bin/rails g` invocation would.
# BEFORE the requires, not after: Base.class_option resolves each option's
# default out of Rails::Generators.options at class-DEFINITION time, so a
# generator required first freezes `orm: false` and its inherited model and
# migration hooks then silently do nothing. `bin/rails g` configures first for
# the same reason; getting this backwards makes the specs assert against half a
# scaffold and notice nothing.
Rails::Generators.configure!(Rails.application.config.generators)

Dir[File.expand_path("../../lib/generators/**/*_generator.rb", __dir__)].each { |file| require file }

module GeneratorHarness
  # Run a generator class against a throwaway destination root, returning
  # everything it printed (say/say_status write to $stdout via Thor's shell,
  # resolved at call time — capturing here is enough).
  #
  # stderr too, because Thor's `start` RESCUES Thor::Error — which
  # Rails::Generators::Error subclasses — and prints it rather than raising.
  # That is right for a CLI (a message, not a backtrace), but it means a
  # generator's refusal is only observable here.
  def run_generator(klass, args = [], destination:)
    out = StringIO.new
    err = StringIO.new
    original_out = $stdout
    original_err = $stderr
    $stdout = out
    $stderr = err
    klass.start(args, destination_root: destination)
    out.string + err.string
  ensure
    $stdout = original_out
    $stderr = original_err
  end

  # Syntax smoke over everything a generator emitted: compile (never run)
  # each Ruby file directly and each ERB view through ActionView's erubi
  # subclass (plain Erubi::Engine can't parse Rails' `<%= tag.div do %>`
  # block-expression form) — a SyntaxError in any template fails the
  # example.
  def expect_valid_generated_sources(destination)
    Dir[File.join(destination, "**/*.rb")].each do |path|
      RubyVM::InstructionSequence.compile(File.read(path), path)
    end
    Dir[File.join(destination, "**/*.erb")].each do |path|
      src = ActionView::Template::Handlers::ERB::Erubi.new(File.read(path)).src
      RubyVM::InstructionSequence.compile(src, path)
    end
  end
end
