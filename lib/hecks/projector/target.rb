module Hecks
  module Projector
    # What makes a module a projection target. `Projector.register` has
    # always accepted anything answering `call(bluebook:, options:)` —
    # this only removes the second step, so a target declares its own key
    # beside its own implementation instead of being registered from
    # somewhere else that has to be kept in sync with it.
    #
    #   module Hecks::Projections::OIDC
    #     extend Hecks::Projector::Target
    #     projects_as :oidc
    #
    #     module_function
    #
    #     def call(bluebook:, options: {}) = { ... }
    #   end
    #
    # Named `Target`, not `Projection`, on purpose. "Projection" already
    # means two other things in this codebase: `Ports::Projection` is
    # read-model catch-up (events folded into view state), and `bin/project`
    # forces that catch-up by hand. Neither has anything to do with
    # "canonical IR in, external artifact out". A third meaning under the
    # same word would make the two impossible to grep apart — and from a
    # domain's point of view `project(X)` really does read as "project to
    # a target", so the narrower word is also the more accurate one.
    module Target
      # Registering at declaration time means `require`ing a target is
      # the whole of installing it — there is no separate manifest that
      # can silently disagree about which targets exist.
      #
      # `requires:` names a capability, not a shape word.
      #
      # This began as `from: :chapter` / `from: :any` — two hand-kept
      # symbols, admitted by duck-typing on `.aggregates`, which is a
      # guess at what "is a chapter" means. The capabilities were already
      # real by then: `Hecks::IR` is the ability to emit IR (its own
      # header says so), and `Behaviour::Chapter` is the ability to answer
      # as a chapter. So a projection names the module it needs, and
      # admission is a genuine check rather than a proxy for one.
      #
      #   projects_as :ir,         requires: Hecks::IR
      #   projects_as :vocabulary                              # chapter, the default
      #
      # It also composes: a projection needing two capabilities names
      # both, instead of a third symbol being invented for the pair.
      #
      # The fail-quiet this closes, unchanged in substance: every
      # construct emits its own IR, so handing a projector an aggregate
      # instead of a chapter is the natural thing to try. `bluebook:` was
      # only ever a parameter name, never a contract. `:oidc` failed
      # loudly (no `aggregates` method), but `:shape` returned
      # `{"name" => "Order", "aggregates" => []}` — well-formed,
      # confident, and wrong.
      # `declares:` names an aggregate the chapter must have.
      #
      # A capability says what a construct can do; this says what it must
      # carry. `:vocabulary` needs a chapter declaring a Vocabulary
      # aggregate, `:parser_table` one declaring Syntax — declared here
      # rather than as a `raise` in the projection's own body, so the
      # requirement is stated instead of written as behaviour. The
      # registry refuses before the projection runs, so the projection
      # itself no longer carries a guard about its own admission.
      # `emits:` says what kind of artifact comes back.
      #
      # `:artifact` (the default) is one thing — a Hash, or a String.
      # `:files` is a tree: a Hash of relative path => contents, which is
      # what a reference-page or codegen projection produces.
      #
      # Declared rather than sniffed, deliberately. Inferring a tree from
      # an ordinary Hash is guesswork — `{"name" => "Pizzas"}` is
      # indistinguishable from a one-file tree — so `write` asks what the
      # projection said rather than inspecting what it returned.
      # Registers `self` as a projection target under `key`, and stores the
      # capability and aggregate requirements `admits!` later checks against.
      #
      # @param key [String, Symbol] the key to register `self` under (converted to a symbol)
      # @param requires [Module, Array<Module>, nil] capability module(s) a construct must
      #   satisfy; nil or empty means `Bluebook::Behaviour::Chapter`
      # @param declares [String, Symbol, Array<String, Symbol>, nil] aggregate name(s) the
      #   chapter must declare; nil means none
      # @param emits [Symbol] the kind of artifact `self` returns: `:artifact` (the default,
      #   a single Hash or String) or `:files` (a path => contents tree)
      # @return [Symbol] the registered key
      def projects_as(key, requires: nil, declares: nil, emits: :artifact)
        @projection_emits    = emits
        @projection_key      = key.to_sym
        @projection_declares = Array(declares)
        @projection_requires = Array(requires)
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
