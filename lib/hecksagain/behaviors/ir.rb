# Hecksagain::Behaviors::{TestSetup,TestCase,BehaviorsSuite}
#
# The `.behaviors` authoring surface's own IR — plain Structs, holding
# exactly what `Hecks.behaviors "Name" do ... end` collected. Deliberately
# NOT part of `Hecksagain::IR`/`emits_ir` — a behaviors suite is never
# collected into a domain Registry (see `Hecksagain.behaviors`), never
# dispatched through MetaValidator, and carries none of the self-hosted
# round-trip machinery a real bluebook construct does. It is a test
# artifact a runner reads on demand, not a domain a boot needs.
module Hecksagain
  module Behaviors
    TestSetup = Struct.new(:command, :args, keyword_init: true)

    TestCase = Struct.new(:description, :tests_command, :on_aggregate, :kind,
                          :setups, :input, :expect, keyword_init: true) do
      # An already-dotted tests_command is a literal FQN; otherwise `on:`
      # composes with the domain name resolved once setups/the tested
      # dispatch actually run (see Expectations — the domain isn't known
      # until `loads` is booted, so it's a runtime concern, not a field
      # here).
      def dotted? = tests_command.to_s.include?(".")

      def query? = kind == :query
    end

    # `loads` — absolute paths, already resolved against the `.behaviors`
    # file's own directory by the DSL (`BehaviorsBuilder#loads`). `path` is
    # the `.behaviors` file itself, kept for error messages.
    BehaviorsSuite = Struct.new(:name, :vision, :loads, :tests, :path, keyword_init: true)
  end
end
