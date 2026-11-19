# frozen_string_literal: true

require_relative "../role_shadow"
require_relative "gated_verbs"

module Hecks
  module Runtime
    module RoleShadow
      # The shadow report of a domain: each dispatch that runs today with no stated caller and would
      # be refused once a role-gated command refuses an unstated caller, read from the declarations
      # alone, so a domain is migrated from a list before refusal is turned on anywhere.
      #
      # It lists every role-gated command (the launcher, the MCP door and specs dispatch with no
      # caller bound) and every policy and saga leg whose target is one (a reaction runs with the
      # caller cleared, `Caller.reaction`). A target no loaded bluebook declares is listed as
      # unresolved, never dropped. It lives beside `RoleShadow` because it reads the rule the
      # runtime applies: the roles `CommandRules::Authorization` checks and the verbs the
      # dispatcher routes. The report lists; it never refuses.
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
                    "#{counts.fetch(:reaction, 0) + counts.fetch(:saga, 0)} reactions to one, " \
                    "#{counts.fetch(:unresolved, 0)} unresolved targets"
          [heading, *rows.map(&:to_s)].join("\n")
        end

        def reaction_rows(bluebook, verbs)
          targets = policy_targets(bluebook) + saga_targets(bluebook)
          targets.filter_map do |kind, source, verb|
            found, roles = verbs.classify(verb)
            next if found == :open

            Row.new(kind: found == :gated ? kind : :unresolved, source: source, verb: verb, roles: roles)
          end
        end

        def policy_targets(bluebook)
          bluebook.policies.select(&:trigger_command).map do |policy|
            [:reaction, "#{bluebook.name}::#{policy.name} on #{policy.on_event}",
             "#{policy.target_domain || bluebook.name}::#{policy.trigger_command}"]
          end
        end

        def saga_targets(bluebook)
          bluebook.process_managers.flat_map do |saga|
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
