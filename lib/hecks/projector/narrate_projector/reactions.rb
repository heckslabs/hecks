module Hecks
  module Projector
    module NarrateProjector
      # The prose for what a chapter causes on its own: its policies and its sagas.
      module Reactions
        module_function

        # The "Reactions" section, or `nil` when the chapter has no policies or sagas.
        def narrative(bluebook, depth)
          return nil if bluebook.policies.empty? && bluebook.process_managers.empty?

          [DocsProjector.h(depth, "Reactions"), *bluebook.policies.map { |policy| policy_sentence(policy) },
           *bluebook.process_managers.map { |saga| saga_sentence(saga) }].join("\n\n")
        end

        # A policy as the sentence saying it fires on its own.
        def policy_sentence(policy)
          elsewhere = policy.target_domain ? " in #{policy.target_domain}" : ""
          "Whenever `#{policy.on_event}` happens, `#{policy.reaches}` fires on its own#{elsewhere} — " \
            "nobody has to ask for it."
        end

        # A saga as the sentence saying where it starts, ends and what it moves through.
        def saga_sentence(saga)
          shape = saga.to_h
          "**#{shape[:name]}** is a saga: it starts when `#{shape[:starts_on]}` happens and ends when " \
            "`#{shape[:ends_on]}` happens, with each run tracked by its `#{shape[:correlates_by]}`. Along the " \
            "way it moves through #{Array(shape[:states]).map { |s| "`#{s}`" }.join(" → ")}."
        end
      end
    end
  end
end
