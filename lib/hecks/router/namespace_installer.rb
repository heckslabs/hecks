require_relative "../fqn"
require_relative "options_proxy"
require_relative "door"

module Hecks
  class Router
    # Installs optional Ruby syntax over an already-loaded router; FQN
    # resolution stays in Router, this only adapts it to constants and methods.
    class NamespaceInstaller
      def initialize(router)
        @router = router
      end

      # Installs every current-version route as a namespace constant/method, plus
      # the aggregate CRUD door and short `Aggregate.verb` shortcuts.
      def install!
        current_entries.each { |entry| install_namespace_entry(entry) }
        install_shortcuts!
        install_aggregate_doors!
        self
      end

      private

      attr_reader :router

      def current_entries = router.available.reject { |entry| entry.fqn.version }

      def install_namespace_entry(entry)
        target = namespace_for(entry.fqn.realm, entry.fqn.domain, entry.fqn.aggregate)
        define_options(target, entry.fqn)
        define_verb(target, entry)
      end

      def define_options(target, fqn)
        active_router = router
        target.define_singleton_method(:options) do |**options|
          OptionsProxy.new(router: active_router, realm: fqn.realm, domain: fqn.domain,
                           aggregate: fqn.aggregate, options: options)
        end
      end

      def define_verb(target, entry)
        active_router = router
        address = entry.fqn.to_s
        route = entry.command? ? :dispatch : :query
        target.define_singleton_method(entry.fqn.verb) { |**args| active_router.public_send(route, address, **args) }
      end

      # `.find`/`.all`/`.count`/`.events`/`.repository`, matching `Hecks.boot`'s
      # door; grouped by (realm, domain, aggregate) since the five don't vary by verb.
      def install_aggregate_doors!
        current_entries.reject { |entry| entry.fqn.aggregate.nil? }
                       .group_by { |entry| [entry.fqn.realm, entry.fqn.domain, entry.fqn.aggregate] }
                       .each_value { |entries| install_aggregate_door(entries.first) }
      end

      def install_aggregate_door(entry)
        door = Door.for(entry)
        return unless door

        define_door_methods(namespace_for(entry.fqn.realm, entry.fqn.domain, entry.fqn.aggregate), door)
      end

      def define_door_methods(target, door)
        target.define_singleton_method(:repository) { door.repository }
        target.define_singleton_method(:count)      { door.repository.count }
        target.define_singleton_method(:events)     { door.events }
        target.define_singleton_method(:find)       { |id| door.find(id) }
        target.define_singleton_method(:all)        { door.all }
      end

      def install_shortcuts!
        current_entries.reject { |entry| entry.fqn.aggregate.nil? }
                       .group_by { |entry| [entry.fqn.aggregate, entry.fqn.verb] }
                       .each { |(aggregate, verb), candidates| install_shortcut(aggregate, verb, candidates) }
      end

      def install_shortcut(aggregate, verb, candidates)
        # Bounded chapters wrap in their own module (`Domain::Aggregate`) so two
        # BCs can both declare `Person` without colliding on `Object::Person`.
        # Folder-spread files of the same chapter aren't BCs, so they still get it.
        return if bounded_chapter?(candidates)

        installer = self
        shortcut_target(aggregate).define_singleton_method(verb) do |**args|
          installer.send(:dispatch_short, candidates, **args)
        end
      end

      def bounded_chapter?(candidates)
        candidates.any? { |entry| entry.dispatcher.registry.bounded?(entry.fqn.domain) }
      end

      def dispatch_short(candidates, **args)
        raise AmbiguousShortRoute, ambiguity_message(candidates) if candidates.length > 1

        entry = candidates.fetch(0)
        entry.command? ? router.dispatch(entry.fqn.to_s, **args) : router.query(entry.fqn.to_s, **args)
      end

      def ambiguity_message(candidates)
        shown = candidates.map { |entry| entry.fqn.to_s }.sort.join(", ")
        "#{candidates.first.fqn.aggregate}.#{candidates.first.fqn.verb} is ambiguous — choose one of: #{shown}"
      end

      def shortcut_target(aggregate)
        constant = Object.const_get(aggregate, false) if Object.const_defined?(aggregate, false)
        if constant && !constant.is_a?(Module)
          raise NameError,
                "cannot install Bluebook shortcut #{aggregate}: it is not a module"
        end

        constant || Object.const_set(aggregate, Module.new)
      end

      def namespace_for(realm, domain, aggregate)
        [realm, domain, aggregate].compact.reduce(Object) do |parent, name|
          constant = parent.const_get(name, false) if parent.const_defined?(name, false)
          if constant && !constant.is_a?(Module)
            raise NameError,
                  "cannot install Bluebook route under #{parent}::#{name}: it is not a module"
          end

          constant || parent.const_set(name, Module.new)
        end
      end
    end
  end
end
