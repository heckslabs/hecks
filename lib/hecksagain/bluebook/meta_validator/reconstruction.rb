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
      # 420 hand-written lines for this because the dispatch half was hand-written
      # too; there is nothing to hand-write when both directions are one table.
      #
      # It targets the IR's SHAPE, not the language's, which is why the encoding
      # knowledge (`Reference<X>`, an append's re-grouping) lives in Readings.
      #
      # WHAT IT CANNOT REBUILD is as important as what it can, and
      # spec/round_trip_spec pins the difference as an exact set. A field the
      # language does not hold shows up there as a named gap; a field it stops
      # holding shows up as a failure.
      class Reconstruction
        include Readings

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
          @members ||= rows(:members)

          {
            name:          text(row[:name]),
            description:   text(row[:description]),
            identified_by: text(row[:identified_by])&.to_sym,
            attributes:    Array(row[:attributes]).map { |field| attribute(field, id) },
            value_objects: under(:value_objects, :aggregate_id, id).map { |vo| value_object(vo) },
            commands:      under(:commands, :aggregate_id, id).map { |cmd| command(cmd) },
            lifecycle:     lifecycle(row),
            entities:      under(:entities, :aggregate_id, id).map { |piece| entity(piece) },
            queries:       under(:queries, :aggregate_id, id).map { |ask| query(ask) }
          }
        end

        # The type came in as the ID of whatever it names, so it goes back out as the
        # name — or, for another aggregate's head, as the encoding the IR spells.
        def attribute(field, aggregate_id)
          type = text(field[:type]).to_s

          {
            name: text(field[:name])&.to_sym,
            type: type.start_with?("#{aggregate_id}.") ? type.delete_prefix("#{aggregate_id}.") : reference_type(type),
            list: text(field[:list]).to_s == "true",
            # THE LANGUAGE DOES NOT HOLD THIS. Aggregate's Field value object carries
            # name, type and list — no default — so an aggregate attribute declared
            # `default:` loses it. Named in spec/round_trip_spec as a gap rather than
            # papered over; the fix is a field on Field, and the walk already has the
            # value to offer.
            default: nil
          }
        end

        def value_object(row)
          {
            name:       text(row[:name]),
            attributes: Array(row[:attributes]).map { |f| shape_field(f) },
            invariants: Array(row[:invariants]).map { |i| rule(i) },
            closed_set: !text(row[:rows]).nil?,
            members:    members_of(row[:id])
          }
        end

        # A closed set's admitted rows. Each Member is its own root because its
        # pairs are an OPEN MAP, which no value object can hold — so they come back
        # the way they went in, one pair at a time.
        def members_of(value_object_id)
          under(:members, :value_object_id, value_object_id).map do |member|
            Array(member[:pairs]).map { |pair| [text(pair[:key]).to_s, text(pair[:value]).to_s] }
          end
        end

        def shape_field(field)
          {
            name:    text(field[:name])&.to_sym,
            type:    text(field[:type]),
            list:    text(field[:list]).to_s == "true",
            default: blank_to_nil(text(field[:default]))
          }
        end

        # ABSENT is not EMPTY, on the way back as much as on the way in: a default
        # never declared arrives as an empty cell and has to go back out as nil.
        def blank_to_nil(value) = value.to_s.empty? ? nil : value

        def rule(row) = { description: text(row[:description]), canonical: text(row[:canonical]) }

        def command(row)
          {
            name:       text(row[:name]),
            role:       text(row[:role]),
            goal:       text(row[:goal]),
            references: text(row[:references]),
            attributes: Array(row[:attributes]).map { |a| shape_field(a) },
            givens:     Array(row[:givens]).map { |g| rule(g) },
            mutations:  mutations(row),
            emits:      Array(row[:emits]).map { |e| text(e[:name]) }
          }
        end

        def query(row)
          {
            name:        text(row[:name]),
            description: text(row[:description]),
            attributes:  Array(row[:attributes]).map { |a| shape_field(a) },
            wheres:      Array(row[:wheres]).map { |w| where_clause(w) },
            order_by:    order_by(row),
            limit:       limit(row)
          }
        end

        # The IR keeps a where's field as a STRING, not a symbol — it is read back
        # out, never called.
        def where_clause(row)
          { field: text(row[:field]), op: text(row[:op]), value: text(row[:value]) }
        end

        def limit(row)
          ceiling = text(row[:limit])
          return nil if ceiling.to_s.empty?

          { value: ceiling }
        end

        # One object in the IR, two fields in the language.
        def order_by(row)
          field = text(row[:order_field])
          return nil if field.to_s.empty?

          { field: field, direction: text(row[:order_way]) }
        end

        # THE APPEND FLATTENING, IN REVERSE.
        #
        # An append binds several fields at once and the language's Change holds one
        # field/kind/source triple, so the walk offers an append once PER BINDING.
        # Rebuilding groups those rows back into the single mutation the IR keeps —
        # which is the only place in this class that undoes something the walk did
        # rather than simply reading it.
        def mutations(row)
          Array(row[:mutations])
            .group_by { |m| [text(m[:target]), text(m[:op])] }
            .map { |(target, op), bindings| mutation(target, op, bindings) }
        end

        def mutation(target, op, bindings)
          base = { target: target.to_sym, op: op.to_sym }
          return base.merge(fields: appended(bindings)) if op == "append"

          base.merge(source: classified(bindings.first))
        end

        def appended(bindings)
          bindings.to_h { |binding| [text(binding[:field]).to_sym, text(binding[:source])] }
        end

        def classified(binding)
          kind  = text(binding[:kind])
          value = text(binding[:source])

          kind == "argument" ? { kind: kind, name: value } : { kind: "literal", value: value }
        end

        def entity(row)
          {
            name:        text(row[:name]),
            description: text(row[:description]),
            # A STRING here, where an aggregate's is a symbol. The IR spells the two
            # differently and the round trip is where you find that out.
            identified_by: text(row[:identified_by]),
            attributes:    Array(row[:attributes]).map { |f| shape_field(f) }
          }
        end

        # Assembled from three fields, because the IR keeps one object where the
        # language keeps the parts — the same difference Readings holds for the
        # walk, in the other direction.
        def lifecycle(row)
          field = text(row[:state_field])
          return nil if field.to_s.empty?

          {
            field:       field,
            default:     text(row[:state_start]),
            transitions: Array(row[:transitions]).map { |t| transition(t) }
          }
        end

        def transition(row)
          {
            command:    text(row[:command]),
            from_state: text(row[:from_state]),
            to_state:   text(row[:to_state])
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
          id = row[:id]

          {
            name:          text(row[:name]),
            correlates_by: text(row[:correlates_by]),
            starts_on:     text(row[:starts_on]),
            ends_on:       text(row[:ends_on]),
            states:        Array(row[:states]).map { |s| text(s[:name]) },
            handlers:      under(:handlers, :process_manager_id, id).map { |h| handler(h) }
          }
        end

        def handler(row)
          {
            event_type: text(row[:event_type]),
            from_state: text(row[:from_state]),
            to_state:   text(row[:to_state]),
            dispatches: under(:dispatches, :handler_id, row[:id]).map { |d| dispatch(d) }
          }
        end

        def dispatch(row)
          {
            command_name: text(row[:command_name]),
            with:         Array(row[:with_spec]).map { |b| [text(b[:key]), text(b[:value])] }
          }
        end

        def read_model(row)
          {
            name:             text(row[:name]),
            description:      text(row[:description]),
            query_name:       text(row[:query_name]),
            reference_name:   text(row[:reference_name])&.to_sym,
            reference_target: text(row[:reference_target]),
            aggregate_heads:  Array(row[:aggregate_heads]).map { |h| head(h) }
          }
        end

        def head(row)
          {
            aggregate: text(row[:aggregate]),
            # A String, like an entity's identified_by. The IR is not uniform about
            # this and only a round trip says so.
            as:        text(row[:as]),
            many:      text(row[:many]).to_s == "true"
          }
        end
      end
    end
  end
end
