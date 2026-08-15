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
      # IT READS LEVEL BY LEVEL, THROUGH `DeclaredIn`, AND NOT THROUGH THE READ
      # MODEL — which is the difference between a reconstruction that can be the
      # SOURCE and one that can only be a check.
      #
      # `Meta.whole_bluebook` gathers a chapter in a single read, and it sorts:
      # `ReadModelInterpreter#matching` ends `.sort_by(&:id)` deliberately, because
      # a store's iteration order is an accident, and a read model returning store
      # order would let that accident leak into an answer.
      # Right for a read model, fatal here — the order a bluebook declares its
      # commands in is a FACT ABOUT THE SOURCE, and the IR is a contract field for
      # field and index for index ; the export carries that order verbatim.
      # `DeclaredIn` preserves it (spec/executes_spec says so), so this asks each
      # level for its own children rather than filtering one sorted gather.
      #
      # The parent key of every level is read from the language's own plan, the same
      # Plan the walk dispatches from — so the two directions really are one table,
      # which is what the header above has always claimed.
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
          @runtime = runtime
          @plan    = Plan.for(MetaValidator.grammar_registry)
          @chapter = runtime.query("Bluebook::Bluebook.Called", name: { value: chapter }).first or
            raise NotFound, "the meta-domain holds no bluebook called #{chapter.inspect}"
        end

        def to_h
          {
            name:             text(@chapter[:name]),
            version:          text(@chapter[:version]),
            vision:           text(@chapter[:vision]),
            classification:   text(@chapter[:classification]),
            formerly_known_as: text(@chapter[:formerly_known_as]),
            aggregates:       declared("Aggregate", chapter_id).map { |row| aggregate(row) },
            read_models:      declared("ReadModel", chapter_id).map { |row| read_model(row) },
            policies:         declared("Policy", chapter_id).map { |row| policy(row) },
            process_managers: declared("ProcessManager", chapter_id).map { |row| process_manager(row) }
          }
        end

        private

        def chapter_id = @chapter[:id].to_s

        # Everything DECLARED IN one parent, in the order it was declared. The key
        # is the one the language's own creating command carries, read from Plan.
        def declared(category, parent_id)
          key = @plan.category(category).parent_key
          @runtime.query("Bluebook::#{category}.DeclaredIn", key.to_sym => { value: parent_id.to_s })
        end

        # ONE DECLARATION, BUILT FROM THE CONTRACT.
        #
        # There were eleven methods here, one per category, each spelling out the same
        # keys `Assembly::Contracts` already names — which is the shape the judge used
        # to have and paid fourteen unoffered verbs for. The keys come from the table
        # now, and the exceptions come from its `reads:` column: a list needs a reader
        # per element, a folded field is gathered rather than fetched, and everything
        # else is one cell.
        #
        # `extra` is what the containment supplies — children, and the folded objects
        # a row cannot hold on its own.
        def declaration(category, row, extra = {})
          contract = Assembly.contract(category)

          contract.fields.each_with_object({}) do |(_keyword, (key, _build)), out|
            next if extra.key?(key)

            out[key] = read_row(contract.reader(key), key, row)
          end.merge(extra)
        end

        def read_row(spec, key, row)
          case spec
          when nil      then text(row[key])
          when :symbol  then text(row[key])&.to_sym
          when :names   then Array(row[key]).map { |held| text(held[:name]) }
          when Array    then read_shaped(spec, key, row)
          else send(spec, row)
          end
        end

        # The readers are the ones `Shapes` already has, called by name — no wrappers,
        # so nothing shadows them. `:each_with_id` is the single exception that needs
        # more than the element: an attribute's type came in as the ID of whatever it
        # names, so reading it back needs the row it belongs to.
        def read_shaped(spec, key, row)
          shape, named = spec

          case shape
          when :each         then Array(row[key]).map { |held| send(named, held) }
          when :each_with_id then Array(row[key]).map { |held| send(named, held, row[:id]) }
          when :call         then send(named, row)
          when :from         then pairs(row[named])
          end
        end

        def pairs(with) = Array(with).map { |binding| [text(binding[:key]), text(binding[:value])] }

        # THE PARTS, IN THE ORDER THEY WENT IN, because the identity is their join
        # and a join read out of order names a different record.
        def identity_paths(row) = Array(row[:identified_by]).map { |part| text(part[:value]).to_s }

        # Every cell of the meta-domain is a single-field value object, so a row
        # arrives holding Values rather than Strings.
        def text(cell)
          return nil if cell.nil?
          return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

          cell
        end

        # An aggregate's OWN verbs and asks — the ones no entity declared. Both carry
        # the parent link either way, because that is the head the reference resolves
        # against, so the entity ones have to be told apart by `entity_id`. Rejecting
        # from an ORDERED read keeps the order.
        def own(category, aggregate_id)
          declared(category, aggregate_id).reject { |row| text(row[:entity_id]).to_s != "" }
        end

        # A piece's own verbs and asks. There is no `DeclaredIn` keyed by entity, so
        # this reads the aggregate's — in declaration order — and keeps the ones that
        # name this piece. `row[:aggregate]` — an ENTITY row's own `reference_to
        # Aggregate` (bare, no `_id` since ADR 0025) — not `entity_id`, which
        # STAYS suffixed below : that one is Command/Query's own EXPLICIT `as:`,
        # never touched by the rename.
        def within(category, row)
          declared(category, text(row[:aggregate]))
            .select { |held| text(held[:entity_id]).to_s == row[:id].to_s }
        end

        def aggregate(row)
          id = row[:id]

          {
            name:          text(row[:name]),
            description:   text(row[:description]),
            identified_by: identity_paths(row),
            attributes:    Array(row[:attributes]).map { |field| attribute(field, id) },
            value_objects: declared("ValueObject", id).map { |shape| value_object(shape) },
            commands:      own("Command", id).map { |verb| command(verb) },
            # THE AGGREGATE BOUNDARY, and the precondition a command may
            # reference by name (S10, ADR 0025 — "Rules") — the same
            # `rule` reader `command`'s own givens/ensures already use
            # (Assembly::Contracts' generic `declaration()` path), read
            # here by hand because `aggregate(row)` itself is hand-typed,
            # unlike `command`/`value_object`/`query` below.
            invariants:    Array(row[:invariants]).map { |held| rule(held) },
            preconditions: Array(row[:preconditions]).map { |held| rule(held) },
            # S12, ADR 0025 — same reason invariants/preconditions are
            # read by hand two lines up: `aggregate(row)` is hand-typed.
            projected_fields: Array(row[:projected_fields]).map { |held| projected_field(held) },
            lifecycle:     lifecycle(row),
            entities:      declared("Entity", id).map { |piece| entity(piece) },
            queries:       own("Query", id).map { |ask| query(ask) },
            provenance:    provenance(row)
          }
        end

        def value_object(row) = declaration("ValueObject", row)

        def closed_set_of(row) = !text(row[:rows]).nil?
        def members_row(row)   = members_of(row[:id])

        # A closed set's admitted rows. Each Member is its own root because its pairs
        # are an OPEN MAP, which no value object can hold — so they come back the way
        # they went in, one pair at a time.
        def members_of(value_object_id)
          declared("Member", value_object_id).map do |member|
            Array(member[:pairs]).map { |pair| [text(pair[:key]).to_s, text(pair[:value]).to_s] }
          end
        end

        def command(row) = declaration("Command", row)

        def query(row) = declaration("Query", row).merge(options_of(row))

        def entity(row)
          {
            name:        text(row[:name]),
            description: text(row[:description]),
            # The same shape as an aggregate's now. It was a String here and a
            # Symbol there — the IR was not uniform about it, and only a round trip
            # ever said so.
            identified_by: identity_paths(row),
            attributes:    Array(row[:attributes]).map { |field| shape_field(field) },
            commands:      within("Command", row).map { |verb| command(verb) },
            queries:       within("Query", row).map { |ask| query(ask) },
            # An entity has its own state machine, and the language has held it all
            # along — Entity.Lifecycle and Entity.Transition were two of the fourteen
            # verbs that started firing when the judge became a walk. Only the
            # reconstruction had never asked for them.
            lifecycle:     lifecycle(row)
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

        def policy(row) = declaration("Policy", row)

        def process_manager(row)
          declaration("ProcessManager", row,
                      handlers: declared("Handler", row[:id]).map { |leg| handler(leg) })
        end

        def handler(row)
          declaration("Handler", row,
                      dispatches: declared("Dispatch", row[:id]).map { |leg| dispatch(leg) })
        end

        def dispatch(row) = declaration("Dispatch", row)

        def read_model(row)
          declaration("ReadModel", row).merge(query_name: text(row[:query_name])).merge(options_of(row))
        end
      end
    end
  end
end
