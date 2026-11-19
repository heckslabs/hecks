# frozen_string_literal: true

module Hecks
  module Runtime
    module RoleShadow
      # The role-gated commands of a set of bluebooks, by fully qualified verb, and how a reaction's
      # target names one: the same verbs the dispatcher routes (`PolicyInterpreter`) and the same
      # roles `CommandRules::Authorization` checks (`Bluebook::Command#role_set`).
      class GatedVerbs
        # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks a domain loads
        def initialize(bluebooks)
          @roles = bluebooks.flat_map { |bluebook| verbs_of(bluebook) }.to_h
        end

        # @return [Hash{String => Array<String>}] each role-gated verb and the roles it declares
        def gated = @roles.reject { |_verb, roles| roles.empty? }

        # What a target names: `:gated` with its roles, `:open` for a command that declares no
        # role or a port operation (no port operation declares a role), `:unresolved` for a verb
        # no loaded bluebook declares.
        #
        # @param verb [String] a fully qualified target, `Domain::Aggregate.Command`
        # @return [Array(Symbol, Array<String>)] the kind and the roles
        def classify(verb)
          return [:open, []] if port_operation?(verb)
          return [:unresolved, []] unless @roles.key?(verb)

          roles = @roles.fetch(verb)
          roles.empty? ? [:open, []] : [:gated, roles]
        end

        private

        # A port operation's target names its port after the aggregate: `Aggregate::Port.Operation`.
        def port_operation?(verb) = verb.split("::", 2).last.include?("::")

        def verbs_of(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            prefix = "#{bluebook.name}::#{aggregate.hecks_name}"
            aggregate.commands.map { |command| ["#{prefix}.#{command.hecks_name}", command.role_set] } +
              entity_verbs(prefix, aggregate)
          end
        end

        def entity_verbs(prefix, aggregate)
          aggregate.entities.flat_map do |entity|
            entity.commands.map { |command| ["#{prefix}.#{entity.hecks_name}.#{command.hecks_name}", command.role_set] }
          end
        end
      end
    end
  end
end
