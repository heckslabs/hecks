module Hecks
  module Projections
    module Diagrams
      # The state diagrams: an aggregate's declared lifecycle and a process manager's saga.
      module Statecharts
        module_function

        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @param holder [Object] an aggregate or entity with a lifecycle
        # @return [String] the lifecycle's states and the commands that move between them
        def lifecycle_diagram(bluebook, holder)
          lifecycle = holder.lifecycle
          edges = lifecycle.transitions.flat_map do |command_name, transition|
            Array(transition.from).map { |from_state| "    #{from_state} --> #{transition.target}: #{command_name}" }
          end

          subject = "#{holder.hecks_name}'s own declared lifecycle (field: #{lifecycle.field})"
          <<~MERMAID
            #{Diagrams.header(bluebook.name, subject)}stateDiagram-v2
                [*] --> #{lifecycle.default}
            #{edges.join("\n")}
          MERMAID
        end

        # @param bluebook [Bluebook::Chapter] the assembled chapter
        # @param saga [Object] a process manager
        # @return [String] the saga's states and what each transition dispatches
        def saga_diagram(bluebook, saga)
          edges = saga.handlers.map { |handler| saga_edge(handler, saga) }

          subject = "#{saga.hecks_name}'s own declared states and what each transition dispatches " \
                    "(starts on #{saga.starts_on}, ends on #{saga.ends_on})"
          <<~MERMAID
            #{Diagrams.header(bluebook.name, subject)}stateDiagram-v2
                [*] --> #{saga.states.first}
            #{edges.join("\n")}
          MERMAID
        end

        # `saga` is needed only for the `REFUSED` edge, whose compensating dispatches are
        # derived from the forward dispatches' `compensates`, not written on the handler.
        def saga_edge(handler, saga)
          label = handler.event_type
          # Derived compensations first, matching the order `SagaInterpreter#unwind` runs them.
          dispatched = handler.event_type == Bluebook::ProcessManager::REFUSED ? derived_compensations(saga) : []
          dispatched += handler.dispatches.map(&:command_name)
          label += " / dispatches #{dispatched.join(", ")}" unless dispatched.empty?

          "    #{handler.from_state} --> #{handler.to_state}: #{label}"
        end

        # Listed in declaration order; at refusal the runtime fires them newest first.
        def derived_compensations(saga)
          saga.handlers.flat_map { |handler| handler.dispatches.filter_map { |dispatch| dispatch.compensates&.command_name } }
        end
      end
    end
  end
end
