# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class RoutingGuard
      # The guard's agreement step: every accepted agreement names the policy that holds it
      # (`Domain:Policy`); while one names a policy no bluebook declares, the session's calls are
      # refused by name, except the call that enforces an agreement again. The policy does the
      # holding; this step only reports a guard that holds nothing. A store that cannot answer
      # warns and allows, so a broken store never stops the call that repairs it.
      class AgreementGate
        REPAIR = /\bAgreement\.enforce!?(?:\s|\z)/i

        # The gate over the settings' stand-ins, or over a booted registry's own records: the
        # accepted agreements its durable Protocols store holds and the policies its bluebooks
        # declare. With no durable store no agreement answers and the gate allows.
        #
        # @param registry [Runtime::Registry, nil] the boot answering the guard
        # @param settings [Hash] `agreements:` and `policies:` callables standing in for the registry
        # @return [AgreementGate]
        def self.build(registry, settings)
          return new(agreements: settings[:agreements], policies: settings[:policies]) if settings.key?(:agreements)

          new(agreements: -> { accepted(registry) }, policies: -> { declared(registry) })
        end

        # @return [Hash{String => String}] reference => guard of each accepted, guarded agreement
        def self.accepted(registry)
          rows = records(registry).select { |found| StartedWork.value(found, :status).to_s == "accepted" }
          pairs = rows.map { |found| [StartedWork.value(found, :reference).to_s, StartedWork.value(found, :enforced_by).to_s] }
          pairs.reject { |_reference, guard| guard.empty? }.to_h
        end

        # @return [Array<Object>] the Agreement records of a durable store, else none
        def self.records(registry)
          bluebook = registry&.bluebook("Protocols")
          agreement = bluebook&.aggregates&.find { |found| found.hecks_name == "Agreement" }
          return [] unless agreement

          repository = registry.repository("Protocols", agreement)
          ScriptGate.memory?(repository) ? [] : repository.all
        end

        # @return [Array<String>] each `Domain:Policy` the registry's bluebooks declare
        def self.declared(registry)
          registry.bluebooks.flat_map { |name, bluebook| bluebook.policies.map { |policy| "#{name}:#{policy.name}" } }
        end

        # @param agreements [#call] answers the accepted agreements' references => guards
        # @param policies [#call] answers the `Domain:Policy` names the bluebooks declare
        def initialize(agreements:, policies:)
          @agreements = agreements
          @policies = policies
        end

        # @param text [String] the Bash command
        # @return [nil] when the call may run
        # @raise [Refused] naming an accepted agreement whose guard resolves to no policy
        def judge!(text:)
          return if text.match?(REPAIR)

          reference, guard = unresolved
          raise Refused, "agreement #{reference} names guard #{guard}, which resolves to no policy: enforce it again" if reference
        rescue Refused
          raise
        rescue StandardError => e
          warn "orchestrator_guard: the agreement rule could not answer (#{e.message}); allowing"
        end

        private

        def unresolved
          known = @policies.call
          @agreements.call.find { |_reference, guard| !known.include?(guard) }
        end
      end
    end
  end
end
