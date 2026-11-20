require_relative "command_names/check"
require_relative "command_names/remedies"
require_relative "command_names/record_only"

module Hecks
  # Reads the places that shell out to the launcher for names the launcher does not accept.
  module CommandNames
    # The clean verdict.
    CLEAN = "every launcher name invoked in workflows, hooks, gate rows, specs and docs is one the launcher accepts".freeze

    # The clean verdict of the remedy check.
    REMEDIES_CLEAN = "every remedy a Ruby refusal or a Rust host refusal names is a command a person or an agent runs".freeze

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

    # @param root [String] the checkout
    # @param runtime [#bluebooks] what `Hecks.describe` answers
    # @return [String] the clean verdict of the remedy check
    # @raise [Failure] with a line for each remedy that names no runnable command
    def check_remedies(root:, runtime:)
      scopes = Adapters::Driving::CliRunner.name_index(runtime: runtime)
      found = Remedies.findings(root: root, scopes: scopes, record_only: RecordOnly.names(runtime))
      raise Failure, found.join("\n") unless found.empty?

      REMEDIES_CLEAN
    end

    # Raised with every finding.
    class Failure < StandardError; end
  end
end
