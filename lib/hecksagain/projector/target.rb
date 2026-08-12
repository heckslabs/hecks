module Hecksagain
  module Projector
    # WHAT MAKES A MODULE A PROJECTION TARGET. `Projector.register` has
    # always accepted anything answering `call(bluebook:, options:)` —
    # this only removes the second step, so a target declares its own key
    # beside its own implementation instead of being registered from
    # somewhere else that has to be kept in sync with it.
    #
    #   module Hecksagain::Projections::OIDC
    #     extend Hecksagain::Projector::Target
    #     projects_as :oidc
    #
    #     module_function
    #
    #     def call(bluebook:, options: {}) = { ... }
    #   end
    #
    # NAMED `Target`, NOT `Projection`, on purpose. "Projection" already
    # means two other things in this codebase: `Ports::Projection` is
    # read-model catch-up (events folded into view state), and `bin/project`
    # forces that catch-up by hand. Neither has anything to do with
    # "canonical IR in, external artifact out". A third meaning under the
    # same word would make the two impossible to grep apart — and from a
    # domain's point of view `project(X)` really does read as "project TO
    # a target", so the narrower word is also the more accurate one.
    module Target
      # Registering at declaration time means `require`ing a target is
      # the whole of installing it — there is no separate manifest that
      # can silently disagree about which targets exist.
      #
      # `requires:` NAMES A CAPABILITY, not a shape word.
      #
      # This began as `from: :chapter` / `from: :any` — two hand-kept
      # symbols, admitted by duck-typing on `.aggregates`, which is a
      # guess at what "is a chapter" means. The capabilities were already
      # real by then: `Hecksagain::IR` is the ability to emit IR (its own
      # header says so), and `Behaviour::Chapter` is the ability to answer
      # as a chapter. So a projection names the module it needs, and
      # admission is a genuine check rather than a proxy for one.
      #
      #   projects_as :ir,         requires: Hecksagain::IR
      #   projects_as :vocabulary                              # chapter, the default
      #
      # It also composes: a projection needing two capabilities names
      # both, instead of a third symbol being invented for the pair.
      #
      # THE FAIL-QUIET THIS CLOSES, unchanged in substance: every
      # construct emits its own IR, so handing a projector an AGGREGATE
      # instead of a chapter is the natural thing to try. `bluebook:` was
      # only ever a PARAMETER NAME, never a contract. `:oidc` failed
      # loudly (no `aggregates` method), but `:shape` returned
      # `{"name" => "Order", "aggregates" => []}` — well-formed,
      # confident, and wrong.
      # `declares:` NAMES AN AGGREGATE THE CHAPTER MUST HAVE.
      #
      # A capability says what a construct can DO; this says what it must
      # CARRY. `:vocabulary` needs a chapter declaring a Vocabulary
      # aggregate, `:parser_table` one declaring Syntax — and both used
      # to state that as a `raise` in their own body, which is a
      # requirement written as behaviour instead of declared. Stated
      # here, the registry refuses before the projection runs and the
      # projection stops carrying a guard about its own admission.
      def projects_as(key, requires: nil, declares: nil)
        @projection_key      = key.to_sym
        @projection_declares = Array(declares)
        @projection_requires = Array(requires)
        Projector.register(@projection_key, self)
        @projection_key
      end

      def projection_key = @projection_key

      # Empty means "a chapter" — resolved HERE rather than as a default
      # argument, because Behaviour::Chapter is not loaded yet when this
      # file is.
      def projection_declares = @projection_declares || []

      def projection_requires
        req = @projection_requires
        req.nil? || req.empty? ? [Bluebook::Behaviour::Chapter] : req
      end
    end
  end
end
