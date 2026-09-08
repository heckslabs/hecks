module Hecks
  module Bluebook
    # A GRAPH BUILT FROM DECLARATIONS, rather than from DSL calls.
    #
    # This is the half that lets the language orchestrate. `Reconstruction` reads a
    # chapter back out of the meta-domain, in declaration order, as plain
    # declarations — the same shape `to_h` spells. This turns those declarations
    # into the graph the runtime runs: IR aggregates with their verbs, value
    # objects, entities and asks, owned by the chapter that declares them.
    #
    # It takes a HASH, not a runtime, on purpose. That makes it a pure inverse of
    # `to_h` and testable without the meta-domain in the picture at all:
    #
    #     Assembly.call(built.to_h).to_h == built.to_h
    #
    # which is the check `spec/assembly_spec` makes for every chapter in the tree.
    # Feed it the reconstruction instead and the same code assembles what the
    # LANGUAGE holds — the only difference being where the declarations came from.
    #
    # EVERY FIELD IS READ FROM ONE TABLE. There is no method per category here:
    # `Contracts` names what the language cannot say about a construct, `Build`
    # reads it, and the coverage gate holds the table to the language. The first
    # draft of this file did have a method each, which is the shape the judge used
    # to have — and the price of that shape was fourteen verbs the language declared
    # and nothing ever offered.
    #
    # What stays hand-written is the CONTAINMENT: which construct holds which.
    # That is not a field table. (The runtime SURFACE is no longer built here at
    # all — the door is a per-boot projection, facade/surface.rb.)
    class Assembly
      def self.call(declaration) = new(declaration).bluebook

      def initialize(declaration)
        @declaration = declaration
      end

      def bluebook
        aggregates = Array(@declaration[:aggregates]).map { |row| AggregateAssembly.new(row).aggregate }
        models     = Array(@declaration[:read_models]).map { |row| Build.call("ReadModel", row) }

        Build.call(
          "Bluebook", @declaration,
          aggregates:       aggregates,
          read_models:      models,
          policies:         reactions(aggregates),
          process_managers: Array(@declaration[:process_managers]).map { |row| process_manager(row) }
        )
      end

      private

      # Every reaction the chapter holds, and each one also handed back to the head
      # that declared it — the builder keeps a policy in BOTH places, hoisting it onto
      # the chapter where the runtime reads it while the head keeps its own list. The
      # language records which head, so the assembly can put it back.
      def reactions(aggregates)
        Array(@declaration[:policies]).map { |row| Build.call("Policy", row) }.each do |reaction|
          next if reaction.aggregate.to_s.empty?

          head = aggregates.find { |held| held.hecks_name == reaction.aggregate }
          head&.policies&.push(reaction)
        end
      end

      def process_manager(row)
        Build.call("ProcessManager", row,
                   handlers: Array(row[:handlers]).map { |leg| handler(leg) })
      end

      def handler(row)
        Build.call("Handler", row,
                   dispatches: Array(row[:dispatches]).map { |leg| dispatch(leg) })
      end

      # `compensates` — a PLAIN HASH on the declaration (`Reconstruction#
      # dispatch`'s own comment for why), built into the real
      # `DispatchSpec` its own field actually is by recursing through
      # THIS SAME method, one level in — the identical move `handler`
      # itself takes into `dispatches`, one level up. `nil` when there
      # is nothing to compensate; `Build.call` never sees a
      # `compensates:` key it does not know how to read either way, the
      # same reason `compensates` never joined `Contract#fields` at all.
      def dispatch(row)
        compensates = row[:compensates] && dispatch(row[:compensates])
        Build.call("Dispatch", row, compensates: compensates)
      end
    end
  end
end
