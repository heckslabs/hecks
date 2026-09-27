module Hecks
  module Projector
    # A projection target declares its own registration key beside its own
    # implementation, instead of a separate registry entry that can drift.
    #
    #   module Hecks::Projections::OIDC
    #     extend Hecks::Projector::Target
    #     projects_as :oidc
    #     def self.call(bluebook:, options: {}) = { ... }
    #   end
    #
    # Named `Target`, not `Projection`, which already means read-model catch-up elsewhere.
    module Target
      # Registers `self` as a projection target under `key`; the registry
      # checks `requires`/`declares` before a projection ever runs, so a
      # projection carries no admission guard of its own.
      #
      # @param key [String, Symbol] key to register `self` under
      # @param requires [Module, Array<Module>, nil] capability module(s) required;
      #   nil/empty means `Bluebook::Behaviour::Chapter`
      # @param declares [String, Symbol, Array, nil] aggregate name(s) the chapter must declare
      # @param emits [Symbol] :artifact (a Hash/String, the default) or :files (a path => tree)
      # @param needs_world [Boolean] true refuses a call made with no `world:` bindings
      # @return [Symbol] the registered key
      def projects_as(key, requires: nil, declares: nil, emits: :artifact, needs_world: false)
        @projection_emits       = emits
        @projection_key         = key.to_sym
        @projection_declares    = Array(declares)
        @projection_requires    = Array(requires)
        @projection_needs_world = needs_world
        Projector.register(@projection_key, self)
        @projection_key
      end

      # Gives the key this target registered under.
      #
      # @return [Symbol, nil] the key given to `projects_as`, or nil before it is called
      def projection_key = @projection_key

      # Empty means "a chapter" — resolved here rather than as a default
      # argument, because Behaviour::Chapter is not loaded yet when this
      # file is.
      #
      # @return [Array<String, Symbol>] aggregate names the chapter must declare; empty
      #   for none
      def projection_declares = @projection_declares || []

      # Gives the kind of artifact this target returns.
      #
      # @return [Symbol] the kind of artifact `self` returns: `:artifact` or `:files`
      def projection_emits = @projection_emits || :artifact

      # Tells whether this target is an export — one that needs a domain's
      # `.world`/`.hecksagon` bindings, passed as `Projector.call`'s `world:`,
      # rather than only its declaration.
      #
      # @return [Boolean] the value given to `projects_as`' `needs_world:`, or false
      #   before `projects_as` is called
      def projection_needs_world? = @projection_needs_world || false

      # Names the capability module(s) a construct must satisfy, defaulting
      # to plain chapter-hood when `projects_as` named none.
      #
      # @return [Array<Module>] required capability modules
      def projection_requires
        req = @projection_requires
        req.nil? || req.empty? ? [Bluebook::Behaviour::Chapter] : req
      end
    end
  end
end
