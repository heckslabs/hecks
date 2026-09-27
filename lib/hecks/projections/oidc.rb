require_relative "../naming"
require_relative "../projector"

module Hecks
  module Projections
    # An OIDC client/scope manifest derived from a domain's IR: the audience, one scope per
    # command, and the roles those commands demand.
    #
    # `verb` matches `Bluebook#verbs` and `role` matches what `Ports::Authorization.holds_role?`
    # compares. Roles come from each command's own `role`, since `.hecksagon` is not visible here.
    # A command with no declared role projects `"role" => nil` rather than being dropped.
    module OIDC
      extend Projector::Target

      projects_as :oidc

      module_function

      # Projects the manifest; `audience:` overrides the domain name (an IdP audience is
      # usually a URL).
      #
      # @param bluebook [Bluebook::Chapter] the chapter being projected
      # @param options [Hash{Symbol => Object}] `:audience` (String, Symbol, nil)
      #   overrides the manifest's `"audience"` value
      # @return [Hash{String => Object}] `"audience"` (String), `"scopes"` (see
      #   `scopes_for`) and `"roles"` (`Array<String>`, every distinct declared role,
      #   sorted)
      def call(bluebook:, options: {})
        scopes = scopes_for(bluebook)

        {
          "audience" => (options[:audience] || bluebook.name).to_s,
          "scopes"   => scopes,
          "roles"    => scopes.map { |scope| scope["role"] }.compact.uniq.sort
        }
      end

      # Every command's scope entry, entity commands included (they dispatch as `Entity.Command`).
      # Sorted by scope so two manifest versions diff cleanly.
      #
      # @param bluebook [Bluebook::Chapter] the chapter being projected
      # @return [Array<Hash{String => Object}>] every command's scope entry (see
      #   `command_scopes`), sorted by `"scope"`
      def scopes_for(bluebook)
        bluebook.aggregates.flat_map { |aggregate| aggregate_scopes(bluebook, aggregate) }
                .sort_by { |scope| scope["scope"] }
      end

      # Projects one aggregate's own commands and every entity nested inside it.
      #
      # @param bluebook [Bluebook::Chapter] the aggregate's owning chapter, for the
      #   verb and scope prefixes
      # @param aggregate [Bluebook::Aggregate] the aggregate being projected
      # @return [Array<Hash{String => Object}>] the aggregate's and its entities'
      #   scope entries (see `command_scopes`)
      def aggregate_scopes(bluebook, aggregate)
        verb_prefix  = "#{bluebook.name}::#{aggregate.hecks_name}"
        scope_prefix = "#{Naming.snake(bluebook.name)}:#{Naming.snake(aggregate.hecks_name)}"

        command_scopes(aggregate.commands, verb_prefix, scope_prefix) +
          aggregate.entities.flat_map { |entity| entity_scopes(entity, verb_prefix, scope_prefix) }
      end

      # Projects an entity's commands, recursing into nested entities (ADR 0026).
      #
      # @param entity [Bluebook::Entity] the entity being projected
      # @param verb_prefix [String] the enclosing aggregate or entity's own verb
      #   prefix, extended with this entity's name
      # @param scope_prefix [String] the enclosing aggregate or entity's own scope
      #   prefix, extended with this entity's snake-cased name
      # @return [Array<Hash{String => Object}>] this entity's and its nested entities'
      #   scope entries (see `command_scopes`)
      def entity_scopes(entity, verb_prefix, scope_prefix)
        verb_prefix  = "#{verb_prefix}.#{entity.hecks_name}"
        scope_prefix = "#{scope_prefix}.#{Naming.snake(entity.hecks_name)}"

        command_scopes(entity.commands, verb_prefix, scope_prefix) +
          entity.entities.flat_map { |piece| entity_scopes(piece, verb_prefix, scope_prefix) }
      end

      # One scope entry per command, spelled like `banking:account.open`; snake-cased through
      # `Naming.snake`, as the facade names its door methods.
      #
      # @param commands [Array<Bluebook::Command>] the commands to project
      # @param verb_prefix [String] the owning aggregate or entity's fully-qualified
      #   verb prefix
      # @param scope_prefix [String] the owning aggregate or entity's snake-cased
      #   scope prefix
      # @return [Array<Hash{String => Object}>] one entry per command: `"scope"`
      #   (String), `"verb"` (String), `"role"` (String, `nil` if the command
      #   declares none)
      def command_scopes(commands, verb_prefix, scope_prefix)
        commands.map do |command|
          {
            "scope" => "#{scope_prefix}.#{Naming.snake(command.hecks_name)}",
            "verb"  => "#{verb_prefix}.#{command.hecks_name}",
            "role"  => command.role
          }
        end
      end
    end
  end
end
