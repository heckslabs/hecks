# Hecks::Behaviors::{TestSetup,TestCase,BehaviorsSuite}
#
# Plain Structs holding what `Hecks.behaviors "Name" do ... end` collected; a suite is never
# collected into a domain Registry.
module Hecks
  # The `.behaviors` toolkit: DSL, IR, runner and rspec shim.
  module Behaviors
    TestSetup = Struct.new(:command, :args, keyword_init: true)

    TestCase = Struct.new(:description, :tests_command, :on_aggregate, :kind,
                          :setups, :input, :expect, keyword_init: true) do
      # Whether `tests_command` is already a fully qualified verb name.
      #
      # @return [Boolean] true when `tests_command` contains a `.`
      #
      # @return [Boolean] true when `tests_command` contains a `.`
      def dotted? = tests_command.to_s.include?(".")

      # Tells whether this test case exercises a query rather than a command.
      #
      # @return [Boolean] true when `kind` is `:query`
      def query? = kind == :query
    end

    # `loads` holds absolute paths resolved against the `.behaviors` file's directory;
    # `path` is that file, kept for error messages.
    BehaviorsSuite = Struct.new(:name, :vision, :loads, :tests, :path, keyword_init: true)
  end
end
