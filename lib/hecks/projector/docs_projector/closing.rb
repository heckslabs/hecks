module Hecks
  module Projector
    module DocsProjector
      # The sections that close a chapter's document: the reactions its policies cause and the
      # sagas it runs.
      module Closing
        module_function

        # The closing sections, or `nil` when the chapter has neither policies nor sagas.
        def call(bluebook, depth)
          out = reaction_lines(bluebook, depth)
          bluebook.process_managers.each { |saga| out.concat(saga_lines(saga, depth)) }
          out.empty? ? nil : out.join("\n")
        end

        # The table of policies, or no lines when the chapter has none.
        def reaction_lines(bluebook, depth)
          return [] if bluebook.policies.empty?

          rows = bluebook.policies.map do |policy|
            ["`#{policy.on_event}`", "`#{policy.reaches}`", policy.target_domain || bluebook.name]
          end
          [DocsProjector.h(depth, "Reactions"), "",
           "These fire on their own. Issuing the verb on the left also causes the one on the right.", "",
           DocsProjector.table(%w[on\ event dispatches in], rows)]
        end

        # The lines describing one saga: where it starts, where it ends, what it correlates by
        # and its states.
        def saga_lines(saga, depth)
          shape = saga.to_h
          [DocsProjector.h(depth, "#{shape[:name]} (a saga)"), "",
           "Starts on `#{shape[:starts_on]}`, ends on `#{shape[:ends_on]}`, " \
           "correlated by `#{shape[:correlates_by]}`.", "",
           "States: #{Array(shape[:states]).map { |s| "`#{s}`" }.join(" → ")}.", ""]
        end
      end
    end
  end
end
