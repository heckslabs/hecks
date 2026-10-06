require "rubocop"
# Not "rubocop/rspec/support": its global include of CopHelper collides with other specs'
# own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../lib/rubocop/cop/hecks/thread_shared_ivar_mutation"

# Builds the annotated Ruby source `expect_offense` and `expect_no_offenses` read: a class in
# Hecks::Runtime holding one method, with the cop's message written under the offending line.
module ThreadSharedIvarSources
  module_function

  # @param ivar [String] the mutated instance variable
  # @param class_name [String] the class holding the mutation
  # @return [String] the offense message the cop writes for the pair
  def message(ivar, class_name)
    "`#{ivar}` is a plain instance variable mutated outside `initialize` on #{class_name}, which is shared " \
      "across every thread dispatching through it (a Puma worker pool, say) — two concurrent threads would " \
      "corrupt each other's view of it, the exact bug already fixed for `Dispatcher#reaction_depth` (see " \
      "dispatcher.rb's `#reenter`). Use `Thread.current[:...]` for per-thread state, or a `Mutex`-guarded " \
      "critical section (`Registry#saga_mutex`) if the state genuinely must be shared."
  end

  # @param code [String] the offending statement
  # @return [String] the caret line under `code`, carrying the cop's message
  def annotation(code, ivar, class_name)
    "#{"^" * code.length} #{message(ivar, class_name)}"
  end

  # @param header [String] the method's name and parameters
  # @param statements [Array<String>] the body, one line each, indented as they should sit
  # @return [String] the method's source
  def method_source(header, *statements)
    body = statements.map { |statement| "  #{statement}\n" }.join
    "def #{header}\n#{body}end\n"
  end

  # @param class_name [String] the class to wrap the method in
  # @param method_source [String] a method's source from `method_source`
  # @return [String] the class inside `module Hecks; module Runtime`
  def in_runtime_class(class_name, method_source)
    body = method_source.lines.map { |line| "    #{line}" }.join
    "module Hecks\n  module Runtime\n    class #{class_name}\n#{body}    end\n  end\nend\n"
  end

  # @return [String] a class whose method mutates `ivar` with `statement`, annotated as an offense
  def offending(class_name, header, statement, ivar)
    in_runtime_class(class_name, method_source(header, statement, annotation(statement, ivar, class_name)))
  end

  NESTED_IN_BLOCK = in_runtime_class(
    "Registry",
    method_source("reset_runtime_state!", "[1, 2].each do |x|", "  @count = x",
                  "  #{annotation("@count = x", "@count", "Registry")}", "end")
  ).freeze
end

# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.describe RuboCop::Cop::Hecks::ThreadSharedIvarMutation do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  # Off so offense messages match the cop's `MSG` without the cop-name badge.
  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }

  def sources = ThreadSharedIvarSources

  # The cop matches by short class name; Dispatcher and Registry live in Hecks::Runtime.
  shared_examples "flags plain ivar mutation" do |class_name|
    it "flags a plain assignment" do
      expect_offense(sources.offending(class_name, "reenter", "@reaction_depth = 1", "@reaction_depth"))
    end

    it "flags an ||= mutation" do
      expect_offense(sources.offending(class_name, "reenter", "@cache ||= {}", "@cache"))
    end

    it "flags an += mutation" do
      expect_offense(sources.offending(class_name, "bump", "@count += 1", "@count"))
    end

    it "flags an in-place << mutation" do
      expect_offense(sources.offending(class_name, "track(event)", "@seen << event", "@seen"))
    end

    it "flags an in-place []= mutation" do
      expect_offense(sources.offending(class_name, "remember(key, value)", "@cache[key] = value", "@cache"))
    end

    it "does not flag assignment inside initialize" do
      expect_no_offenses(sources.in_runtime_class(class_name,
                                                  sources.method_source("initialize", "@reaction_depth = 0", "@cache = {}")))
    end

    it "allows the Thread.current-backed fix itself" do
      fix = sources.method_source("reenter", "depth = Thread.current[:hecks_reaction_depth].to_i",
                                  "Thread.current[:hecks_reaction_depth] = depth + 1")
      expect_no_offenses(sources.in_runtime_class(class_name, fix))
    end
  end

  it_behaves_like "flags plain ivar mutation", "Dispatcher"

  it "does not flag plain ivar mutation in an unrelated class" do
    expect_no_offenses(sources.in_runtime_class("CommandInterpreter", sources.method_source("call", "@count = 1", "@seen << :x")))
  end

  it "does not flag a local variable that merely looks like it (no @ sigil)" do
    expect_no_offenses(sources.in_runtime_class("Dispatcher", sources.method_source("reenter", "depth = 1", "depth += 1")))
  end

  it "flags a plain ivar mutation nested inside a block within a non-initialize method" do
    expect_offense(ThreadSharedIvarSources::NESTED_IN_BLOCK)
  end
end
