module Hecksagain
  module Bluebook
    # A GRAPH BUILT FROM DECLARATIONS, rather than from DSL calls.
    #
    # This is the half that lets the language orchestrate. `Reconstruction` reads a
    # chapter back out of the meta-domain, in declaration order, as plain
    # declarations — the same shape `to_h` spells. This turns those declarations
    # into the graph the runtime runs: aggregate classes with their verbs defined,
    # value objects nested inside them, entities, asks, the chapter's namespace.
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
    # What stays hand-written is the CONTAINMENT and the PROJECTION: which construct
    # holds which, and how a head becomes a Ruby class with verbs on it. Neither is
    # a field table.
    class Assembly
      def self.call(declaration) = new(declaration).bluebook

      def initialize(declaration)
        @declaration = declaration
      end

      def bluebook
        aggregates = Array(@declaration[:aggregates]).map { |row| AggregateAssembly.new(row).aggregate }
        models     = Array(@declaration[:read_models]).map { |row| Build.call("ReadModel", row) }

        chapter = Build.call(
          "Bluebook", @declaration,
          aggregates:       aggregates,
          read_models:      models,
          policies:         Array(@declaration[:policies]).map { |row| Build.call("Policy", row) },
          process_managers: Array(@declaration[:process_managers]).map { |row| process_manager(row) }
        )

        Installation.new(chapter, models).install
        chapter
      end

      private

      def process_manager(row)
        Build.call("ProcessManager", row,
                   handlers: Array(row[:handlers]).map { |leg| handler(leg) })
      end

      def handler(row)
        Build.call("Handler", row,
                   dispatches: Array(row[:dispatches]).map { |leg| Build.call("Dispatch", leg) })
      end
    end
  end
end
