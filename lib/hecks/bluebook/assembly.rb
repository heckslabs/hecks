module Hecks
  module Bluebook
    # A graph built from declarations, rather than from DSL calls.
    #
    # This is the half that lets the language orchestrate. `Reconstruction` reads a
    # chapter back out of the meta-domain, in declaration order, as plain
    # declarations — the same shape `to_h` spells. This turns those declarations
    # into the graph the runtime runs: IR aggregates with their verbs, value
    # objects, entities and asks, owned by the chapter that declares them.
    #
    # ## Why a hash, not a runtime
    #
    # It takes a hash, not a runtime, on purpose. That makes it a pure inverse of
    # `to_h` and testable without the meta-domain in the picture at all:
    #
    #     Assembly.call(built.to_h).to_h == built.to_h
    #
    # which is the check `spec/assembly_spec` makes for every chapter in the tree.
    # Feed it the reconstruction instead and the same code assembles what the
    # language holds — the only difference being where the declarations came from.
    #
    # ## One table, not a method per category
    #
    # Every field is read from one table. There is no method per category here:
    # `Contracts` names what the language cannot say about a construct, `Build`
    # reads it, and the coverage gate holds the table to the language. A method
    # per category can decorate a verb the language declares without ever
    # offering it; the table cannot, because `spec/assembly_spec` checks every
    # field the language declares against it.
    #
    # ## What stays hand-written
    #
    # The containment — which construct holds which — stays hand-written; it is
    # not a field table. The runtime surface is no longer built here at all — the
    # door is a per-boot projection, facade/surface.rb.
    class Assembly
      # Builds the graph the runtime runs from one chapter's declared hash.
      #
      # @param declaration [Hash{Symbol => Object}] a chapter's declarations, in the
      #   shape `Chapter#to_h` spells
      # @return [Bluebook::Chapter] the assembled chapter, with its aggregates, read
      #   models and process managers built and wired
      def self.call(declaration) = new(declaration).bluebook

      # @param declaration [Hash{Symbol => Object}] a chapter's declarations, in the
      #   shape `Chapter#to_h` spells
      def initialize(declaration)
        @declaration = declaration
      end

      # Assembles this instance's declared hash into the chapter's runtime graph.
      #
      # @return [Bluebook::Chapter] the assembled chapter, with its aggregates, read
      #   models and process managers built and wired
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
      # that declared it — the builder keeps a policy in both places, hoisting it onto
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

      # `compensates` — a plain hash on the declaration (`Reconstruction#
      # dispatch`'s own comment for why), built into the real
      # `DispatchSpec` its own field actually is by recursing through
      # this same method, one level in — the identical move `handler`
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
