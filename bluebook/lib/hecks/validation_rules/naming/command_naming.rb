begin
  require "rwordnet"
rescue LoadError
  # rwordnet is optional — verb checking degrades to custom verbs only
end

module Hecks
  module ValidationRules
    module Naming

    # Hecks::ValidationRules::Naming::CommandNaming
    #
    # Validates that command names start with a verb (e.g. +CreatePizza+,
    # +UpdateOrder+). Uses WordNet for verb detection when the +rwordnet+ gem
    # is available; falls back to custom verbs only when it is not.
    #
    # Custom verbs can be registered in two ways:
    # 1. Via +domain.custom_verbs+ (an array of strings)
    # 2. Via a +verbs.txt+ file at the root of the domain folder (one word per line)
    #
    # Part of the ValidationRules::Naming group -- run by +Hecks.validate+.
    #
    class CommandNaming < BaseRule
      # Checks all commands across all aggregates and returns errors for any
      # command whose name does not start with a recognized verb.
      #
      # @return [Array<String>] error messages for commands with non-verb prefixes
      def errors
        custom = load_custom_verbs
        result = []
        @domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            first_word = cmd.name.split(/(?=[A-Z])/).first
            unless verb?(first_word, custom)
              result << error("Command #{cmd.name} in #{agg.name} doesn't start with a verb",
                hint: "Try '#{suggest_verb(first_word, agg.name)}' or register '#{first_word}' as a custom verb in verbs.txt")
            end
          end
        end
        result
      end

      private

      # Suggests an alternative verb-prefixed command name when the original
      # does not start with a verb.
      #
      # @param first_word [String] the non-verb first word of the command name
      # @param agg_name [String] the aggregate name for context
      # @return [String] a suggested command name (e.g. "CreatePizzaFoo")
      def suggest_verb(first_word, agg_name)
        suffix = first_word == agg_name ? "" : first_word
        "Create#{agg_name}#{suffix}"
      end

      BUILT_IN_VERBS = %w[
        Create Update Delete Remove Add Set Place Cancel Send Submit
        Approve Reject Accept Decline Confirm Deny
        Register Activate Suspend Retire Deactivate Archive
        Open Close Resolve Complete Start Stop Finish
        Assign Transfer Move Promote Demote
        Request Revoke Grant Renew Extend Expire
        Report Investigate Mitigate Escalate
        Deploy Decommission Plan Schedule
        Record Log Track Audit
        Derive Classify Initiate Import Export
        Notify Alert Publish Broadcast
        Lock Unlock Block Unblock Enable Disable
        Verify Validate Check Review Inspect
        Sign Seal Stamp Mark Tag
        Pay Charge Refund Bill Invoice
        Ship Deliver Return Receive
        Connect Disconnect Link Unlink Attach Detach
      ].freeze

      # Checks whether a word is a recognized verb, either from the built-in
      # list, custom verbs, or via WordNet lookup.
      #
      # @param word [String] the word to check (case-insensitive)
      # @param custom [Array<String>] custom verbs registered by the domain
      # @return [Boolean] true if the word is a recognized verb
      def verb?(word, custom)
        lower = word.downcase
        return true if BUILT_IN_VERBS.any? { |v| v.downcase == lower }
        return true if custom.any? { |v| v.downcase == lower }
        return false unless defined?(WordNet)
        WordNet::Lemma.find_all(lower).any? { |l| l.pos == "v" }
      end

      # Loads custom verbs from +domain.custom_verbs+ and from a +verbs.txt+
      # file located alongside the domain source file.
      #
      # @return [Array<String>] combined list of custom verbs
      def load_custom_verbs
        verbs = @domain.respond_to?(:custom_verbs) ? Array(@domain.custom_verbs) : []
        if @domain.respond_to?(:source_path) && @domain.source_path
          verbs_file = File.join(File.dirname(@domain.source_path), "verbs.txt")
          if File.exist?(verbs_file)
            verbs += File.readlines(verbs_file).map(&:strip).reject(&:empty?)
          end
        end
        verbs
      end
    end
    Hecks.register_validation_rule(CommandNaming)
    end
  end
end
