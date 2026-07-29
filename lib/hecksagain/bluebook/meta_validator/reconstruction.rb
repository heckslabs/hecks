module Hecksagain
  module Bluebook
    module MetaValidator
      # A bluebook rebuilt FROM the meta-domain, in the shape the builder produces.
      #
      # This is the second half of the claim at the top of bluebook.bluebook —
      # "loading a domain becomes dispatching commands into this meta-domain ; the
      # IR it stores must equal the IR the DSL builder produces". The judge is the
      # first half. This reads the records back and assembles `to_h`.
      #
      # It is the INVERSE OF THE WALK and shares its plan: the walk reads a node's
      # lists through the command that appends to each, and this reads them back out
      # of the rows those commands wrote. The retired `experiment/replay.rb` needed
      # 420 hand-written lines because the dispatch half was hand-written too; there
      # is nothing to hand-write when both directions are one table.
      #
      # This file is the TRAVERSAL. The hashes at its tips, and the encodings they
      # undo, are in Shapes.
      #
      # WHAT IT CANNOT REBUILD matters as much as what it can, and
      # spec/round_trip_spec pins the difference as an exact set: a field the language
      # does not hold appears there as a named gap, and a field it stops holding
      # appears as a failure.
      class Reconstruction
        include Readings
        include Shapes

        def self.of(runtime, chapter) = new(runtime, chapter).to_h

        def initialize(runtime, chapter)
          @whole = runtime.query("Meta.whole_bluebook", bluebook: chapter).first or
            raise NotFound, "the meta-domain holds no bluebook called #{chapter.inspect}"
        end

        def to_h
          chapter = @whole[:bluebook]

          {
            name:             text(chapter[:name]),
            vision:           text(chapter[:vision]),
            classification:   text(chapter[:classification]),
            aggregates:       rows(:aggregates).map { |row| aggregate(row) },
            read_models:      rows(:read_models).map { |row| read_model(row) },
            policies:         rows(:policies).map { |row| policy(row) },
            process_managers: rows(:process_managers).map { |row| process_manager(row) }
          }
        end

        private

        # Every cell of the meta-domain is a single-field value object, so a row
        # arrives holding Values rather than Strings.
        def text(cell)
          return nil if cell.nil?
          return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

          cell
        end

        def rows(name) = Array(@whole[name])

        # Children are found by the parent id they were declared under — the same
        # reference the `DeclaredIn` queries read.
        def under(name, key, parent_id)
          rows(name).select { |row| text(row[key]) == parent_id }
        end

        def aggregate(row)
          id = row[:id]

          {
            name:          text(row[:name]),
            description:   text(row[:description]),
            identified_by: text(row[:identified_by])&.to_sym,
            attributes:    Array(row[:attributes]).map { |field| attribute(field, id) },
            value_objects: under(:value_objects, :aggregate_id, id).map { |shape| value_object(shape) },
            commands:      under(:commands, :aggregate_id, id).map { |verb| command(verb) },
            lifecycle:     lifecycle(row),
            entities:      under(:entities, :aggregate_id, id).map { |piece| entity(piece) },
            queries:       under(:queries, :aggregate_id, id).map { |ask| query(ask) }
          }
        end

        def value_object(row)
          {
            name:       text(row[:name]),
            attributes: Array(row[:attributes]).map { |field| shape_field(field) },
            invariants: Array(row[:invariants]).map { |assertion| rule(assertion) },
            closed_set: !text(row[:rows]).nil?,
            members:    members_of(row[:id])
          }
        end

        # A closed set's admitted rows. Each Member is its own root because its pairs
        # are an OPEN MAP, which no value object can hold — so they come back the way
        # they went in, one pair at a time.
        def members_of(value_object_id)
          under(:members, :value_object_id, value_object_id).map do |member|
            Array(member[:pairs]).map { |pair| [text(pair[:key]).to_s, text(pair[:value]).to_s] }
          end
        end

        def command(row)
          {
            name:       text(row[:name]),
            role:       text(row[:role]),
            goal:       text(row[:goal]),
            references: text(row[:references]),
            attributes: Array(row[:attributes]).map { |argument| shape_field(argument) },
            givens:     Array(row[:givens]).map { |given| rule(given) },
            mutations:  mutations(row),
            emits:      Array(row[:emits]).map { |announcement| text(announcement[:name]) }
          }
        end

        def query(row)
          {
            name:        text(row[:name]),
            description: text(row[:description]),
            attributes:  Array(row[:attributes]).map { |argument| shape_field(argument) },
            wheres:      Array(row[:wheres]).map { |filter| where_clause(filter) },
            order_by:    order_by(row),
            limit:       limit(row)
          }
        end

        def entity(row)
          {
            name:        text(row[:name]),
            description: text(row[:description]),
            # A STRING here, where an aggregate's is a symbol. The IR is not uniform
            # about this and only a round trip says so.
            identified_by: text(row[:identified_by]),
            attributes:    Array(row[:attributes]).map { |field| shape_field(field) }
          }
        end

        # Assembled from three fields, because the IR keeps one object where the
        # language keeps the parts — the same difference Readings holds for the walk,
        # in the other direction.
        def lifecycle(row)
          field = text(row[:state_field])
          return nil if field.to_s.empty?

          {
            field:       field,
            default:     text(row[:state_start]),
            transitions: Array(row[:transitions]).map { |move| transition(move) }
          }
        end

        def policy(row)
          {
            name:            text(row[:name]),
            on_event:        text(row[:on_event]),
            trigger_command: text(row[:trigger_command]),
            target_domain:   text(row[:target_domain])
          }
        end

        def process_manager(row)
          {
            name:          text(row[:name]),
            correlates_by: text(row[:correlates_by]),
            starts_on:     text(row[:starts_on]),
            ends_on:       text(row[:ends_on]),
            states:        Array(row[:states]).map { |state| text(state[:name]) },
            handlers:      under(:handlers, :process_manager_id, row[:id]).map { |leg| handler(leg) }
          }
        end

        def handler(row)
          {
            event_type: text(row[:event_type]),
            from_state: text(row[:from_state]),
            to_state:   text(row[:to_state]),
            dispatches: under(:dispatches, :handler_id, row[:id]).map { |leg| dispatch(leg) }
          }
        end

        def dispatch(row)
          {
            command_name: text(row[:command_name]),
            with:         Array(row[:with_spec]).map { |binding| [text(binding[:key]), text(binding[:value])] }
          }
        end

        def read_model(row)
          {
            name:             text(row[:name]),
            description:      text(row[:description]),
            query_name:       text(row[:query_name]),
            reference_name:   text(row[:reference_name])&.to_sym,
            reference_target: text(row[:reference_target]),
            aggregate_heads:  Array(row[:aggregate_heads]).map { |gathered| head(gathered) }
          }
        end
      end
    end
  end
end
