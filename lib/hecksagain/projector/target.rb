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
      def projects_as(key)
        @projection_key = key.to_sym
        Projector.register(@projection_key, self)
        @projection_key
      end

      def projection_key = @projection_key
    end
  end
end
