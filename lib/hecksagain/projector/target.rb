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
      # `from:` IS THE FIX FOR A REAL FAIL-QUIET. Every construct emits
      # its own IR now (see Hecksagain::IR), so handing a projector an
      # AGGREGATE instead of a chapter is the natural thing to try — and
      # `bluebook:` was only ever a PARAMETER NAME, never a contract, so
      # nothing checked. `:oidc` failed loudly (no `aggregates` method),
      # but `:shape` returned `{"name" => "Order", "aggregates" => []}`:
      # well-formed, confident, and wrong, because
      # `StorageShape.project`'s own `domain["aggregates"] || []` reads a
      # key an aggregate's IR does not carry. A silently empty answer is
      # worse than a crash.
      #
      #   from: :chapter   needs a whole Bluebook (walks .aggregates)
      #   from: :any       works on any construct that emits IR
      def projects_as(key, from: :chapter)
        @projection_key   = key.to_sym
        @projection_scope = from
        Projector.register(@projection_key, self)
        @projection_key
      end

      def projection_key = @projection_key

      # Defaults to :chapter rather than :any — a target written before
      # this existed takes a whole bluebook, and guessing the permissive
      # answer for it would preserve exactly the silent-empty-answer bug
      # this is here to close.
      def projection_scope = @projection_scope || :chapter
    end
  end
end
