require_relative "../naming"
require_relative "../projector"

module Hecks
  module Projections
    # AN OIDC CLIENT/SCOPE MANIFEST derived from a domain's own IR: what
    # an identity provider has to know about this domain before it can
    # issue a token that means anything here.
    #
    # THE ARTIFACT HALF OF SOMETHING ALREADY HALF-BUILT.
    # `spec/oidc_projection_spec.rb` covers the INTEGRATION half — verified
    # claims in, `IdentityResolution.resolve` → `Authorization.holds_role?`
    # → a dispatch scoped by `Hecks.as_caller(role:)`. That half enforces
    # a role per command. It just had no way to say, up front and as data,
    # WHICH role each command wants — every answer came from asking the
    # live runtime one dispatch at a time.
    #
    # This is that catalogue, and the two are checked against each other
    # rather than merely coexisting: `verb` here is spelled exactly as
    # `Runtime::Dispatcher#dispatch` takes it and exactly as
    # `Bluebook#verbs` lists it, so a scope can never name a command
    # the domain does not have (spec/projections/oidc_projection_spec.rb
    # holds the two lists equal), and `role` is the same string
    # `Ports::Authorization.holds_role?` compares against a real
    # `Governance::RoleAssignment`.
    #
    # ROLES COME FROM THE COMMANDS, NOT FROM GOVERNANCE. A command's own
    # `role "Compliance officer"` is in the bluebook IR
    # (`Command#role`), whereas `uses_framework "Governance"` is
    # declared in the `.hecksagon` — which `call(bluebook:, options:)`
    # cannot see at all. Reading the commands is both the only thing
    # available here AND the more accurate source: it says what each
    # command actually demands, not merely which role vocabulary the
    # application happened to mount.
    #
    # A command with no declared role projects `"role" => nil` rather
    # than being dropped — an unguarded command is a real fact about the
    # domain, and silently omitting it would make the manifest read as
    # though the command did not exist.
    module OIDC
      extend Projector::Target

      projects_as :oidc

      module_function

      # `audience:` overrides the domain name, for the ordinary case
      # where the IdP's registered audience is a URL rather than a bare
      # chapter name.
      def call(bluebook:, options: {})
        scopes = scopes_for(bluebook)

        {
          "audience" => (options[:audience] || bluebook.name).to_s,
          "scopes"   => scopes,
          "roles"    => scopes.map { |scope| scope["role"] }.compact.uniq.sort
        }
      end

      # Sorted by scope, not left in declaration order — a manifest is
      # something two versions of get diffed, and the same precedent
      # `StorageShape.project` sets for its own aggregate list.
      #
      # Recurses into entities, not just an aggregate's own direct
      # commands — the exact same gap `Bluebook#verbs` closed for the
      # same reason (`chapter.rb`'s own comment): a command reached
      # through `Dispatcher#dispatch`'s dotted `Entity.Command` routing
      # is real and callable, so a manifest that never names it can
      # never grant a client a scope for it either.
      def scopes_for(bluebook)
        bluebook.aggregates.flat_map { |aggregate| aggregate_scopes(bluebook, aggregate) }
                .sort_by { |scope| scope["scope"] }
      end

      def aggregate_scopes(bluebook, aggregate)
        verb_prefix  = "#{bluebook.name}::#{aggregate.hecks_name}"
        scope_prefix = "#{Naming.snake(bluebook.name)}:#{Naming.snake(aggregate.hecks_name)}"

        command_scopes(aggregate.commands, verb_prefix, scope_prefix) +
          aggregate.entities.flat_map { |entity| entity_scopes(entity, verb_prefix, scope_prefix) }
      end

      # S17, ADR 0026 — an entity can nest further entities (`Dispatch`,
      # inside `Handler`), so this recurses the same way `Chapter#verbs`
      # now does. The verb and scope prefixes grow in lockstep, each
      # `.`-joined the same way its own kind already was.
      def entity_scopes(entity, verb_prefix, scope_prefix)
        verb_prefix  = "#{verb_prefix}.#{entity.hecks_name}"
        scope_prefix = "#{scope_prefix}.#{Naming.snake(entity.hecks_name)}"

        command_scopes(entity.commands, verb_prefix, scope_prefix) +
          entity.entities.flat_map { |piece| entity_scopes(piece, verb_prefix, scope_prefix) }
      end

      # `banking:account.open` — the shape an OIDC scope is conventionally
      # spelled in, and snake_cased through the SAME `Naming.snake` the
      # facade uses to name a command's own door method, so a scope and
      # the Ruby call that satisfies it cannot drift apart.
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
