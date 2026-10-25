module Hecks
  module Rails
    # The domain a Rails app booted, held once so models, routes and controllers reach it
    # without each booting their own.
    module Booted
      class << self
        # Boots a domain directory and holds the dispatcher it answers.
        #
        # @param path [String] the directory holding the app's bluebooks
        # @param environment [String, nil] the environment overlay to boot under
        # @return [Object] the dispatcher
        def boot(path, environment: nil)
          @dispatcher = Hecks.boot(path, environment: environment || Hecks::Assembly::FROM_ENV)
        end

        # @return [Object] the dispatcher the app booted
        # @raise [RuntimeError] if no domain has been booted
        def dispatcher = @dispatcher || raise("no Hecks domain booted; call Hecks::Rails::Booted.boot")

        # @return [Array<Hecks::Bluebook::Chapter>] the booted chapters the app declared, without
        #   the ones a hecksagon attached, such as Governance
        def app_chapters = registry.bluebooks.values.reject { |chapter| registry.bounded?(chapter.name) }

        # @return [Boolean] whether a domain has been booted
        def booted? = !@dispatcher.nil?

        # @return [Object] the booted registry
        def registry = dispatcher.registry

        # Finds a booted chapter by name, ignoring case, so `hecks_routes "ledger"` finds Ledger.
        #
        # @param name [String, Symbol] the chapter's name in any case
        # @return [Hecks::Bluebook::Chapter] the chapter
        # @raise [KeyError] if no booted chapter has that name
        def chapter(name)
          registry.bluebooks.each { |chapter_name, chapter| return chapter if chapter_name.to_s.casecmp?(name.to_s) }
          raise KeyError, "no booted chapter named #{name}"
        end

        # The aggregate's module in the booted domain. A chapter with a `namespace` keeps its
        # aggregates out of the top level, leaving a Rails model free to take their names.
        #
        # @param chapter_name [String] a booted chapter's name
        # @param aggregate_name [String] one of its aggregates
        # @return [Module] the module the Ruby driving adapter installed for the aggregate
        def door(chapter_name, aggregate_name)
          booted = chapter(chapter_name)
          Object.const_get("#{booted.namespace || booted.name}::#{aggregate_name}")
        end

        # Forgets the held dispatcher.
        #
        # @return [nil]
        def reset! = @dispatcher = nil
      end
    end
  end
end
