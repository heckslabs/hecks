# Hecks::Behaviors::{TestSetup,TestCase,BehaviorsSuite}
#
# The `.behaviors` authoring surface's own IR — plain Structs, holding
# exactly what `Hecks.behaviors "Name" do ... end` collected. Deliberately
# not part of `Hecks::IR`/`emits_ir` — a behaviors suite is never
# collected into a domain Registry (see `Hecks.behaviors`), never
# dispatched through MetaValidator, and carries none of the self-hosted
# round-trip machinery a real bluebook construct does. It is a test
# artifact a runner reads on demand, not a domain a boot needs.
module Hecks
  # The `.behaviors` toolkit: the DSL a `.behaviors` file is written against
  # (`Hecks.behaviors`, dsl.rb), the plain-Struct IR it builds (this file), the runner
  # that boots a suite's domain and checks each test (runner.rb, expectations.rb), and
  # an rspec shim for a consuming app's own suite (rspec.rb).
  module Behaviors
    TestSetup = Struct.new(:command, :args, keyword_init: true)

    TestCase = Struct.new(:description, :tests_command, :on_aggregate, :kind,
                          :setups, :input, :expect, keyword_init: true) do
      # Tells whether `tests_command` is already a fully qualified verb name.
      #
      # An already-dotted tests_command is a literal FQN; otherwise `on:`
      # composes with the domain name resolved once setups/the tested
      # dispatch actually run (see Expectations — the domain isn't known
      # until `loads` is booted, so it's a runtime concern, not a field
      # here).
      #
      # @return [Boolean] true when `tests_command` contains a `.`
      def dotted? = tests_command.to_s.include?(".")

      # Tells whether this test case exercises a query rather than a command.
      #
      # @return [Boolean] true when `kind` is `:query`
      def query? = kind == :query
    end

    # `loads` — absolute paths, already resolved against the `.behaviors`
    # file's own directory by the DSL (`BehaviorsBuilder#loads`). `path` is
    # the `.behaviors` file itself, kept for error messages.
    BehaviorsSuite = Struct.new(:name, :vision, :loads, :tests, :path, keyword_init: true)
  end
end
