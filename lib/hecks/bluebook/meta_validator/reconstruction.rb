require_relative "reconstruction/reading"
require_relative "reconstruction/heads"

module Hecks
  module Bluebook
    module MetaValidator
      # A bluebook rebuilt from the meta-domain, in the shape the DSL builder's `to_h` produces.
      # Reads level by level through `DeclaredIn`, not the read model, to preserve declared order.
      class Reconstruction
        include Readings
        include Shapes
        include Reading
        include Heads

        # Reads one judged chapter back out of `runtime` and assembles it.
        def self.of(runtime, chapter) = new(runtime, chapter).to_h

        def initialize(runtime, chapter)
          @runtime = runtime
          @plan    = Plan.for(MetaValidator.grammar_registry)
          @chapter = runtime.query("Bluebook::Bluebook.Called", name: { value: chapter }).first or
            raise Runtime::NotFound, "the meta-domain holds no bluebook called #{chapter.inspect}"
        end

        def to_h
          chapter_fields.merge(
            aggregates:       declared_as("Aggregate", :aggregate),
            read_models:      declared_as("ReadModel", :read_model),
            policies:         declared_as("Policy", :policy),
            process_managers: declared_as("ProcessManager", :process_manager)
          )
        end

        private

        def chapter_id = @chapter[:id].to_s

        def closed_set?(row) = !text(row[:rows]).nil?

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

        # Everything of `category` declared in the chapter, each row read back by `builder`.
        def declared_as(category, builder)
          declared(category, chapter_id).map { |row| send(builder, row) }
        end

        # What the chapter itself holds, apart from what is declared in it.
        def chapter_fields
          {
            name:              text(@chapter[:name]),
            version:           text(@chapter[:version]),
            vision:            text(@chapter[:vision]),
            classification:    text(@chapter[:classification]),
            formerly_known_as: text(@chapter[:formerly_known_as]),
            namespace:         text(@chapter[:namespace]),
            attaches_to:       attached_contexts(@chapter),
            provides:          provisions(@chapter)
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
