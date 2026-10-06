module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # The commands of a chapter and the events they emit: every command that emits an event
          # must agree on its shape, and the shapes and identities are looked up by event name.
          module EventShapes
            private

            # Every command that emits a given event must agree on its structural shape
            # (name, type, list, optional); `pattern:`/`admits:`/`default:` may differ (ADR 0025).
            def validate_event_shapes!(aggregates)
              event_emitters(aggregates).each do |event_name, pairs|
                next if pairs.size == 1

                refuse_divergent_event!(event_name, pairs) if divergent_shapes?(pairs, aggregates)
              end
            end

            def divergent_shapes?(pairs, aggregates)
              pairs.map { |(owner, command)| event_shape(command, owner_aggregate(owner, aggregates)) }.uniq.size > 1
            end

            def refuse_divergent_event!(event_name, pairs)
              named = pairs.map { |(owner, command)| "#{owner}.#{command.hecks_name}" }.sort
              raise Malformed,
                    "#{event_name.inspect} is emitted with different shapes by #{named.join(" and ")} — " \
                    "an event is one fact, and every command that emits it must declare the same fields"
            end

            # Yields every command the chapter declares with its owner's name
            # ("Aggregate.Entity" for entities).
            def each_command(aggregates)
              return enum_for(:each_command, aggregates) unless block_given?

              aggregates.each do |aggregate|
                aggregate.commands.each { |command| yield aggregate.hecks_name, command }
                aggregate.entities.each do |entity|
                  entity.commands.each { |command| yield "#{aggregate.hecks_name}.#{entity.hecks_name}", command }
                end
              end
            end

            # Not memoised: a chapter split across files is validated once per file, and a
            # cached index would miss the commands later files add.
            def event_emitters(aggregates)
              each_command(aggregates).with_object(Hash.new { |h, k| h[k] = [] }) do |(owner, command), index|
                command.emits.each { |event_name| index[event_name] << [owner, command] }
              end
            end

            # The comparable shape of a command's attributes, value objects unwrapped.
            # Structural, not nominal: aggregates may type a field with differently named
            # wrapper value objects without disagreeing about the event. `owner` supplies the
            # `value_object` lookup, since same-named value objects are private to each aggregate.
            def event_shape(command, owner)
              command.attributes.map { |a| shape_row(owner, a, []) }.sort
            end

            def shape_row(owner, attribute, seen)
              [attribute.name, unwrap_shape(owner, attribute.type.to_s, seen), attribute.list?, attribute.optional?]
            end

            def unwrap_shape(owner, type_name, seen = [])
              return type_name if owner.nil?
              return type_name if Attribute::PRIMITIVES.include?(type_name)
              # a self-referential value object bottoms out on its own name
              return type_name if seen.include?(type_name)

              shape = owner.value_object(type_name)
              return type_name unless shape

              shape.attributes.map { |a| shape_row(owner, a, seen + [type_name]) }.sort
            end

            # The value objects a command's fields can be
            # typed with are the aggregate's own (`Entity` carries no
            # `value_object` lookup), so only the owner string's first segment matters.
            def owner_aggregate(owner, aggregates)
              aggregates.find { |a| a.hecks_name == owner.to_s.split(".").first }
            end

            def event_shape_for(event_name, aggregates)
              pairs = event_emitters(aggregates).fetch(event_name.to_s, [])
              return nil if pairs.empty?

              owner_name, command = pairs.first
              event_shape(command, owner_aggregate(owner_name, aggregates))
            end

            # An entity's event is stamped with its owning aggregate's identity, so
            # "Game.Knight" answers Game's heads.
            def event_identity_heads_for(event_name, aggregates)
              pairs = event_emitters(aggregates).fetch(event_name.to_s, [])
              return [] if pairs.empty?

              owner_name, = pairs.first
              aggregate = owner_aggregate(owner_name, aggregates)
              aggregate ? identity_heads_through(aggregate, owner_name) : []
            end

            # An entity's event also carries the piece's own identity: the args a piece
            # was addressed by are its payload (`Emission#emit`).
            def identity_heads_through(aggregate, owner_name)
              entity = piece_named(aggregate, owner_name)
              aggregate.identity_heads.map(&:to_sym) + (entity ? entity.identity_heads.map(&:to_sym) : [])
            end

            def piece_named(aggregate, owner_name)
              owner_name.to_s.split(".").drop(1).reduce(aggregate) do |owner, name|
                owner&.entities&.find { |e| e.hecks_name == name }
              end
            end

            def command_lookup(aggregates)
              each_command(aggregates).with_object({}) do |(owner, command), index|
                index["#{owner}.#{command.hecks_name}"] = command
              end
            end
          end
        end
      end
    end
  end
end
