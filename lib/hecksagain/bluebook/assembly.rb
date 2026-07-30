module Hecksagain
  module Bluebook
    # A GRAPH BUILT FROM DECLARATIONS, rather than from DSL calls.
    #
    # This is the half that lets the language orchestrate. `Reconstruction` reads a
    # chapter back out of the meta-domain, in declaration order, as plain
    # declarations — the same shape `to_h` spells. This turns those declarations
    # into the graph the runtime actually runs: aggregate classes with their verbs
    # defined, value objects nested inside them, entities, asks, the chapter's
    # namespace.
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
    # Nothing here decides anything. Every rule about whether a declaration is
    # admissible was enforced on the way in, by the language.
    class Assembly
      def self.call(declaration) = new(declaration).bluebook

      def initialize(declaration)
        @declaration = declaration
      end

      def bluebook
        aggregates = Array(@declaration[:aggregates]).map { |row| aggregate(row) }
        models     = Array(@declaration[:read_models]).map { |row| read_model(row) }

        chapter = IR::Bluebook.new(
          name:             @declaration[:name],
          version:          @declaration[:version],
          vision:           @declaration[:vision],
          classification:   @declaration[:classification],
          aggregates:       aggregates,
          read_models:      models,
          policies:         Array(@declaration[:policies]).map { |row| policy(row) },
          process_managers: Array(@declaration[:process_managers]).map { |row| process_manager(row) }
        )

        Installation.new(chapter, models).install
        chapter
      end

      private

      def aggregate(row)
        AggregateAssembly.new(row).aggregate
      end

      def read_model(row)
        IR::ReadModel.new(
          name:             row[:name],
          description:      row[:description],
          reference_name:   row[:reference_name],
          reference_target: row[:reference_target],
          aggregate_heads:  Array(row[:aggregate_heads]).map { |head| symbolise(head) }
        )
      end

      def policy(row)
        IR::Policy.new(
          name:            row[:name],
          on_event:        row[:on_event],
          trigger_command: row[:trigger_command],
          target_domain:   row[:target_domain]
        )
      end

      def process_manager(row)
        IR::ProcessManager.new(
          name:          row[:name],
          correlates_by: row[:correlates_by],
          starts_on:     row[:starts_on],
          ends_on:       row[:ends_on],
          states:        Array(row[:states]),
          handlers:      Array(row[:handlers]).map { |leg| handler(leg) }
        )
      end

      def handler(row)
        IR::ProcessManagerHandler.new(
          event_type: row[:event_type],
          from_state: row[:from_state],
          to_state:   row[:to_state],
          dispatches: Array(row[:dispatches]).map { |leg| dispatch(leg) }
        )
      end

      def dispatch(row)
        # `with_spec` is the member ; `with` is only the spelling `to_h` gives it.
        # Each binding's value rides `render_value`, which marks a Symbol with a
        # leading colon — lose that and an argument reads as a string of the same
        # name.
        IR::DispatchSpec.new(
          command_name: row[:command_name],
          with_spec:    Array(row[:with]).to_h { |key, value| [key.to_sym, Marks.read(value)] }
        )
      end

      # A read model's gathered head is a raw hash the interpreter destructures by
      # key, so the keys have to be symbols whichever way the declaration arrived.
      def symbolise(head) = head.to_h { |key, value| [key.to_sym, value] }
    end
  end
end
