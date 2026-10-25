module Hecks
  module Rails
    # Defines a `Hecks::Rails::Model` class for each aggregate the app has not written one for, so
    # a model file exists only where there are presentation methods to put in it.
    #
    # Also defines `ApplicationRecord`, the base a hand-written model inherits, unless the app
    # has one.
    #
    # A chapter a hecksagon attached (Governance and the like) gets none; the app's own chapters do.
    #
    # The Ruby driving adapter installs a top-level module per aggregate at boot, which would claim
    # the name a model wants. `discard_facades!` removes those right after boot, before Zeitwerk
    # registers the app's own model files, and `generate!` runs on every prepare, so a reload
    # starts from a clean slate and a model file the app adds later is respected.
    module Skins
      class << self
        # Removes the top-level modules the driving adapter installed for the booted aggregates.
        #
        # @return [void]
        def discard_facades!
          each_aggregate do |_chapter, aggregate|
            name = aggregate.hecks_name
            facade = Hecks::Namespace::GENERATED[[Object, name]]
            Object.send(:remove_const, name) if facade && installed?(name, facade)
          end
        end

        # Defines a skin for every aggregate whose name is still free.
        #
        # @return [Array<String>] the names it defined
        def generate!
          discard_generated!
          define_base
          each_aggregate { |chapter, aggregate| define(chapter, aggregate.hecks_name) }
          generated.keys
        end

        # @return [Hash{String => String}] each generated skin's name, and the chapter it binds
        def generated = @generated ||= {}

        private

        def define_base
          return if Object.const_defined?(:ApplicationRecord, false)

          Object.const_set(:ApplicationRecord, Class.new(Model))
          generated["ApplicationRecord"] = nil
        end

        def define(chapter, name)
          return warn_duplicate(chapter, name) if generated.key?(name) && generated[name] != chapter.name
          return if Object.const_defined?(name, false)

          Object.const_set(name, Class.new(ApplicationRecord) { aggregate "#{chapter.name}.#{name}" })
          generated[name] = chapter.name
        end

        def warn_duplicate(chapter, name)
          warn "[hecks-rails] #{name} is declared by #{generated[name]} and #{chapter.name}; " \
               "the skin binds #{generated[name]}. Write app/models/#{name.downcase}.rb to choose."
        end

        def installed?(name, facade) = Object.const_defined?(name, false) && Object.const_get(name, false).equal?(facade)

        def discard_generated!
          generated.each_key { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
          generated.clear
        end

        def each_aggregate
          Booted.app_chapters.each do |chapter|
            chapter.aggregates.each { |aggregate| yield chapter, aggregate }
          end
        end
      end
    end
  end
end
