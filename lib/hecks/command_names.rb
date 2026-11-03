require_relative "command_names/check"

module Hecks
  # Reads the places that shell out to the launcher for names the launcher does not accept.
  module CommandNames
    # The clean verdict.
    CLEAN = "every launcher name invoked in workflows, hooks, gate rows, specs and docs is one the launcher accepts".freeze

    module_function

    # @param root [String] the checkout
    # @param runtime [#registry] what `Hecks.describe` answers
    # @return [String] the clean verdict
    # @raise [Failure] with a line for each name the launcher would refuse
    def check(root:, runtime:)
      scopes = Adapters::Driving::CliRunner.name_index(runtime: runtime)
      found = Check.findings(root: root, scopes: scopes)
      raise Failure, found.join("\n") unless found.empty?

      CLEAN
    end

    # Raised with every finding.
    class Failure < StandardError; end
  end
end
