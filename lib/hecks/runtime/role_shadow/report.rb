# frozen_string_literal: true

require_relative "../role_shadow"
require_relative "gated_verbs"

module Hecks
  module Runtime
    module RoleShadow
      # The shadow report of a domain: each dispatch a caller that states no role would be refused
      # under `HECKS_ROLE_ENFORCEMENT=enforce`, read from the declarations alone, so a domain is
      # migrated from a list.
      #
      # It lists every role-gated command a caller may dispatch (a `policy_only` one takes no
      # caller and is left out), every policy whose target is one and that declares no `acts_as`
      # (the unstated caller in a cascade a caller began), every policy whose `acts_as` its target
      # does not declare (a role mismatch), and every saga leg whose target is one (it runs
      # unchecked, as the system). A target no loaded bluebook declares is listed as unresolved.
      # It reads the rule `CommandRules::Authorization` and the dispatcher's re-entry apply, and
      # never refuses.
      module Report
        # One line of the report.
        Row = Struct.new(:kind, :source, :verb, :roles, keyword_init: true) do
          # @return [String] the row as the report prints it
          def to_s
            via = source ? "#{source} -> " : ""
            [kind.to_s.ljust(10), "#{via}#{verb}", (roles.empty? ? "" : "roles: #{roles.join(" or ")}")]
              .join(" ").rstrip
          end
        end

        # The heading's second line: how to clear each kind of row.
        HOW_TO_CLEAR = "a command row needs its caller to state a role (--as on the launcher, role: over MCP); " \
                       "a reaction row needs acts_as on its policy; a mismatch row needs an acts_as its target " \
                       "declares; a saga row runs unchecked"

        module_function

        # The report of a domain directory, from its declarations; no adapter is bound.
        #
        # @param directory [String] a domain directory
        # @return [String] the heading with the counts, then one line per row
        def of_directory(directory)
          render(directory, rows(bluebooks_in(directory)))
        end

        # @return [Array<Bluebook::Declaration>] the bluebooks a domain directory loads
        def bluebooks_in(directory)
          registry = Runtime.describe(directory).registry
          registry.bluebooks.values
        end

        # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks a domain loads
        # @return [Array<Row>] the commands, then the reactions, then the unresolved targets
        def rows(bluebooks)
          verbs = GatedVerbs.new(bluebooks)
          commands = verbs.gated.map { |verb, roles| Row.new(kind: :command, verb: verb, roles: roles) }
          reactions = bluebooks.flat_map { |bluebook| reaction_rows(bluebook, verbs) }
          commands.sort_by(&:verb) + reactions.sort_by { |row| [row.kind == :unresolved ? 1 : 0, row.to_s] }
        end

        # @return [String] the counts, then each row
        def render(directory, rows)
          counts = rows.group_by(&:kind).transform_values(&:size)
          heading = "role shadow report for #{directory}: #{counts.fetch(:command, 0)} role-gated commands, " \
                    "#{counts.fetch(:reaction, 0) + counts.fetch(:mismatch, 0) + counts.fetch(:saga, 0)} reactions to one, " \
                    "#{counts.fetch(:unresolved, 0)} unresolved targets"
          [heading, HOW_TO_CLEAR, *rows.map(&:to_s)].join("\n")
        end

        def reaction_rows(bluebook, verbs)
          targets = policy_targets(bluebook) + saga_targets(bluebook)
          targets.filter_map do |kind, source, verb, acts_as|
            found, roles = verbs.classify(verb)
            next if found == :open || (acts_as && roles.include?(acts_as))

            Row.new(kind: row_kind(found, kind, acts_as), source: source, verb: verb, roles: roles)
          end
        end

        # A gated target's row is a reaction, a saga leg, or a mismatch when its `acts_as` is not
        # among the target's roles.
        def row_kind(found, kind, acts_as)
          return :unresolved unless found == :gated

          acts_as ? :mismatch : kind
        end

        def policy_targets(bluebook)
          bluebook.policies.select(&:trigger_command).map do |policy|
            [:reaction, "#{bluebook.name}::#{policy.name} on #{policy.on_event}",
             "#{policy.target_domain || bluebook.name}::#{policy.trigger_command}", policy.acts_as]
          end
        end

        def saga_targets(bluebook)
          bluebook.sagas.flat_map do |saga|
            saga.handlers.flat_map do |handler|
              handler.dispatches.map do |dispatch|
                [:saga, "#{bluebook.name}::#{saga.name} on #{handler.event_type}", "#{bluebook.name}::#{dispatch.command_name}"]
              end
            end
          end
        end
      end
    end
  end
end
