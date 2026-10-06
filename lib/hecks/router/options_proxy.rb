require_relative "../fqn"

module Hecks
  class Router
    class NamespaceInstaller
      # Returned by `.options(version:)`; forwards command/query verbs to the
      # router, pinned to this FQN version rather than the router's default.
      class OptionsProxy
        # Only the `:version` keyword is accepted; any other key raises `ArgumentError`.
        def initialize(router:, realm:, domain:, aggregate:, options:)
          unknown = options.keys - [:version]
          raise ArgumentError, "unknown router options: #{unknown.join(", ")}" unless unknown.empty?

          @router = router
          @realm = realm
          @domain = domain
          @aggregate = aggregate
          @version = options[:version]&.to_s
        end

        def method_missing(verb, **args)
          fqn = fqn_for(verb)
          fqn.command? ? @router.dispatch(fqn.to_s, **args) : @router.query(fqn.to_s, **args)
        end

        def respond_to_missing?(verb, include_private = false)
          Fqn.command_name?(verb) || Fqn.query_name?(verb) || super
        end

        private

        def fqn_for(verb)
          if Fqn.command_name?(verb)
            Fqn.command(realm: @realm, domain: @domain, version: @version, aggregate: @aggregate, command: verb)
          elsif Fqn.query_name?(verb)
            Fqn.query(realm: @realm, domain: @domain, version: @version, aggregate: @aggregate, query: verb)
          else
            raise NoMethodError, "#{verb.inspect} is not a Bluebook command or query"
          end
        end
      end
    end
  end
end
