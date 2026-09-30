module Hecks
  module Bluebook
    module MetaValidator
      # A bluebook rebuilt from the meta-domain, in the shape the DSL builder's `to_h` produces.
      # Reads level by level through `DeclaredIn`, not the read model, to preserve declared order.
      class Reconstruction
        include Readings
        include Shapes

        # Reads one judged chapter back out of `runtime` and assembles it.
        def self.of(runtime, chapter) = new(runtime, chapter).to_h

        def initialize(runtime, chapter)
          @runtime = runtime
          @plan    = Plan.for(MetaValidator.grammar_registry)
          @chapter = runtime.query("Bluebook::Bluebook.Called", name: { value: chapter }).first or
            raise Runtime::NotFound, "the meta-domain holds no bluebook called #{chapter.inspect}"
        end

        def to_h
          {
            name:              text(@chapter[:name]),
            version:           text(@chapter[:version]),
            vision:            text(@chapter[:vision]),
            classification:    text(@chapter[:classification]),
            formerly_known_as: text(@chapter[:formerly_known_as]),
            namespace:         text(@chapter[:namespace]),
            attaches_to:       attached_contexts(@chapter),
            provides:          provisions(@chapter),
            aggregates:        declared("Aggregate", chapter_id).map { |row| aggregate(row) },
            read_models:       declared("ReadModel", chapter_id).map { |row| read_model(row) },
            policies:          declared("Policy", chapter_id).map { |row| policy(row) },
            process_managers:  declared("ProcessManager", chapter_id).map { |row| process_manager(row) }
          }
        end

        private

        def chapter_id = @chapter[:id].to_s

        # Everything declared in one parent, in the order it was declared. The key
        # is the one the language's own creating command carries, read from Plan.
        def declared(category, parent_id)
          key = @plan.category(category).parent_key
          @runtime.query("Bluebook::#{category}.DeclaredIn", key.to_sym => { value: parent_id.to_s })
        end

        # One declaration, built from the contract's field table. `extra` supplies
        # children and folded objects a row cannot hold on its own.
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

        # `Shapes`'s own readers, called by name. `:each_with_id` also passes the
        # row, since an attribute's type arrives as the ID of what it names.
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

        # The parts, in the order they went in, because the identity is their join
        # and a join read out of order names a different record.
        def identity_paths(row) = Array(row[:identified_by]).map { |part| text(part[:value]).to_s }

        # The contexts one chapter names itself onto, in the order they were
        # attached — same shape identity_paths reads back, one level up.
        def attached_contexts(row) = Array(row[:attaches_to]).map { |part| text(part[:value]).to_s }

        def provisions(row)
          Array(row[:provides]).map do |part|
            { capability: text(part[:capability]).to_s, key: text(part[:key]).to_s, verb: text(part[:verb]).to_s }
          end
        end

        # Every cell of the meta-domain is a single-field value object, so a row
        # arrives holding Values rather than Strings.
        def text(cell)
          return nil if cell.nil?
          return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

          cell
        end

        # An aggregate's own verbs/asks, told apart from an entity's by `entity_id`;
        # both carry the same parent link. Selecting from an ordered read keeps order.
        def own(category, aggregate_id)
          declared(category, aggregate_id).select { |row| text(row[:entity_id]).to_s == "" }
        end

        # A piece's own verbs/asks: no `DeclaredIn` is keyed by entity, so this
        # queries by `row[:aggregate]` and filters the results by `entity_id`.
        def within(category, row)
          declared(category, text(row[:aggregate]))
            .select { |held| text(held[:entity_id]).to_s == row[:id].to_s }
        end

        def aggregate(row)
          id = row[:id]

          {
            name:             text(row[:name]),
            description:      text(row[:description]),
            identified_by:    identity_paths(row),
            attributes:       Array(row[:attributes]).map { |field| attribute(field, id) },
            value_objects:    declared("ValueObject", id).map { |shape| value_object(shape) },
            commands:         own("Command", id).map { |verb| command(verb) },
            # Read by hand, not via `declaration()`, since this method builds its
            # hash directly; `rule` is the same reader `command`'s own uses.
            invariants:       Array(row[:invariants]).map { |held| rule(held) },
            preconditions:    Array(row[:preconditions]).map { |held| rule(held) },
            projected_fields: Array(row[:projected_fields]).map { |held| projected_field(held) },
            lifecycle:        lifecycle(row),
            entities:         direct_entities(id, id).map { |piece| entity(piece) },
            queries:          own("Query", id).map { |ask| query(ask) },
            provenance:       provenance(row)
          }
        end

        def value_object(row) = declaration("ValueObject", row)

        def closed_set_of(row) = !text(row[:rows]).nil?

        # A closed set's admitted rows live inline on the value object's own
        # dispatched state, one member at a time, not behind a `DeclaredIn` query.
        def members_row(row) = members_of(row)

        # The key is stringified, never the value: a pair's value keeps whatever
        # native Ruby type the source line actually wrote.
        def members_of(value_object_row)
          Array(value_object_row[:members]).map do |member|
            Array(member[:pairs]).map { |pair| [text(pair[:key]).to_s, text(pair[:value])] }
          end
        end

        def command(row) = declaration("Command", row)

        def query(row) = declaration("Query", row).merge(options_of(row))

        # Every entity sharing one root aggregate; `owner` (not the root id) tells
        # a direct entity apart from one nested further in.
        def direct_entities(root_id, owner_id)
          declared("Entity", root_id).select { |held| text(held[:owner]).to_s == owner_id.to_s }
        end

        def entity(row)
          {
            name:          text(row[:name]),
            description:   text(row[:description]),
            identified_by: identity_paths(row),
            attributes:    Array(row[:attributes]).map { |field| shape_field(field, text(row[:aggregate])) },
            preconditions: Array(row[:preconditions]).map { |held| rule(held) },
            invariants:    Array(row[:invariants]).map { |held| rule(held) },
            commands:      within("Command", row).map { |verb| command(verb) },
            queries:       within("Query", row).map { |ask| query(ask) },
            entities:      direct_entities(text(row[:aggregate]), row[:id]).map { |piece| entity(piece) },
            lifecycle:     lifecycle(row)
          }
        end

        # Assembled from three fields, because the IR keeps one object where the
        # language keeps the parts.
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

        # A process manager's handlers live inline on its own dispatched state,
        # not behind a `DeclaredIn` query.
        def process_manager(row)
          declaration("ProcessManager", row,
                      handlers: Array(row[:handlers]).map { |leg| handler(leg) })
        end

        # A handler's dispatches, nested one level further in, the same way.
        def handler(row)
          declaration("Handler", row,
                      dispatches: Array(row[:dispatches]).map { |leg| dispatch(leg) })
        end

        # `compensates` folds two flat fields on this row into one object; an
        # absent `compensates_command_name` means a plain dispatch with nothing to undo.
        def dispatch(row)
          name = text(row[:compensates_command_name])
          compensates = name && { command_name: name, with_spec: pairs(row[:compensates_with_spec]) }

          declaration("Dispatch", row, compensates: compensates)
        end

        def read_model(row)
          declaration("ReadModel", row).merge(query_name: text(row[:query_name])).merge(options_of(row))
        end
      end
    end
  end
end
