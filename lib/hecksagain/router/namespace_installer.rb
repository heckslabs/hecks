module Hecksagain
  class Router
    # Installs optional Ruby syntax over an already-loaded router. FQN
    # resolution stays in Router; this object only adapts it to constants and
    # method calls.
    class NamespaceInstaller
      class OptionsProxy
        def initialize(router:, realm:, domain:, aggregate:, options:)
          unknown = options.keys - [:version]
          raise ArgumentError, "unknown router options: #{unknown.join(', ')}" unless unknown.empty?

          @router, @realm, @domain, @aggregate = router, realm, domain, aggregate
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

      def initialize(router)
        @router = router
      end

      def install!
        current_entries.each { |entry| install_namespace_entry(entry) }
        install_shortcuts!
        self
      end

      private

      attr_reader :router

      def current_entries = router.available.reject { |entry| entry.fqn.version }

      def install_namespace_entry(entry)
        target  = namespace_for(entry.fqn.realm, entry.fqn.domain, entry.fqn.aggregate)
        address = entry.fqn.to_s
        active_router = router
        target.define_singleton_method(:options) do |**options|
          OptionsProxy.new(router: active_router, realm: entry.fqn.realm, domain: entry.fqn.domain,
                           aggregate: entry.fqn.aggregate, options: options)
        end
        if entry.command?
          target.define_singleton_method(entry.fqn.verb) { |**args| active_router.dispatch(address, **args) }
        else
          target.define_singleton_method(entry.fqn.verb) { |**args| active_router.query(address, **args) }
        end
      end

      def install_shortcuts!
        installer = self
        current_entries.reject { |entry| entry.fqn.aggregate.nil? }
                       .group_by { |entry| [entry.fqn.aggregate, entry.fqn.verb] }
                       .each do |(aggregate, verb), candidates|
          shortcut_target(aggregate).define_singleton_method(verb) { |**args| installer.send(:dispatch_short, candidates, **args) }
        end
      end

      def dispatch_short(candidates, **args)
        if candidates.length > 1
          shown = candidates.map { |entry| entry.fqn.to_s }.sort.join(", ")
          aggregate, verb = candidates.first.fqn.aggregate, candidates.first.fqn.verb
          raise AmbiguousShortRoute, "#{aggregate}.#{verb} is ambiguous — choose one of: #{shown}"
        end

        entry = candidates.fetch(0)
        entry.command? ? router.dispatch(entry.fqn.to_s, **args) : router.query(entry.fqn.to_s, **args)
      end

      def shortcut_target(aggregate)
        constant = Object.const_get(aggregate, false) if Object.const_defined?(aggregate, false)
        raise NameError, "cannot install Bluebook shortcut #{aggregate}: it is not a module" if constant && !constant.is_a?(Module)

        constant || Object.const_set(aggregate, Module.new)
      end

      def namespace_for(realm, domain, aggregate)
        [realm, domain, aggregate].compact.reduce(Object) do |parent, name|
          constant = parent.const_get(name, false) if parent.const_defined?(name, false)
          raise NameError, "cannot install Bluebook route under #{parent}::#{name}: it is not a module" if constant && !constant.is_a?(Module)

          constant || parent.const_set(name, Module.new)
        end
      end
    end
  end
end
