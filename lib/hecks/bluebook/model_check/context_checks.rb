require_relative "context_map_checks"
require_relative "classification_checks"
require_relative "context_cycles"

module Hecks
  module Bluebook
    module ModelCheck
      # The checks over how contexts relate to each other: a `translates` has to listen to a context
      # this hecksagon acknowledges, and no two contexts may depend on each other ({ContextCycles}).
      module ContextChecks
        include ContextMapChecks
        include ClassificationChecks
        include ContextCycles

        # A `translates` reacts to a foreign event, so the context that owns that event has to be
        # attached or subscribed to, as an `across` policy's target does.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook whose policies are checked
        # @param hecksagon [Bluebook::Hecksagon, nil] the bluebook's own wiring
        # @param owners [Hash{String => Array<String>}, nil] each aggregate name to the contexts
        #   that declare it; nothing is checked without it
        # @return [Array<Finding>] one finding per translates whose source is not acknowledged
        def translates_source_findings(bluebook, hecksagon, owners)
          return [] unless hecksagon && owners

          translated = bluebook.policies.select { |policy| hecksagon.translates.include?(policy.name.to_s) }
          translated.filter_map { |policy| unacknowledged_source_finding(bluebook, policy, hecksagon, owners) }
        end

        # The aggregate name is not unique across contexts, so a source counts as acknowledged when
        # any context that declares it is.
        def unacknowledged_source_finding(bluebook, policy, hecksagon, owners)
          sources = Array(owners[Naming.qualifier(policy.on_event)]).map(&:to_s)
          return if sources.empty? || sources.include?(bluebook.name.to_s)
          return if sources.any? { |source| acknowledged_source?(hecksagon, source) }

          Finding.new(kind: :unacknowledged_source, severity: :error, subject: policy.name,
                      message: unacknowledged_source_message(policy, sources))
        end

        # @return [String] what is wrong and the two ways to acknowledge the source
        def unacknowledged_source_message(policy, sources)
          "translates #{policy.on_event.inspect}, which #{sources.join(" or ")} owns, but " \
            "nothing in this hecksagon acknowledges it — add attaches #{sources.first.inspect} " \
            "or subscribe \"#{sources.first}.SomeEvent\""
        end

        # @return [Boolean] whether the hecksagon attaches the context or subscribes to its events
        def acknowledged_source?(hecksagon, source)
          hecksagon.attaches?(source) || hecksagon.subscriptions.any? { |event| Naming.qualifier(event) == source }
        end
      end
    end
  end
end
