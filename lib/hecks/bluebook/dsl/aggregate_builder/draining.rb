module Hecks
  module Bluebook
    module DSL
      # The words that queue a nested piece, command or query, and the build of what they
      # queued once every sibling has been seen.
      class AggregateBuilder
        # Queues a piece nested in this aggregate, built later once every sibling has been seen.
        #
        # @param name [String] the nested piece's name
        # @yield the piece body, evaluated against an `EntityBuilder` once drained
        # @return [Array<Array>] every pending piece queued so far, this one last
        def entity_impl(name, &block)
          @pending_entities << [name, block]
        end

        # Queues a query declared on this aggregate, built later once every sibling has been seen.
        #
        # @param name [String] the query's name
        # @yield the query body, evaluated against a `QueryBuilder` once drained
        # @return [Array<Array>] every pending query queued so far, this one last
        def query_impl(name, &block)
          @pending_queries << [name, block]
        end

        # Queues a command declared on this aggregate, built later once every sibling has been
        # seen.
        #
        # `from:` is checked against this aggregate's own lifecycle field, never a target
        # state or transition, so a guard can't drift out of sync with the state machine.
        #
        # @param name [String] the command's name
        # @param from [String, Symbol, Array<String, Symbol>, nil] the lifecycle state(s) this
        #   command guards from; nil admits from any state
        # @yield the command body, evaluated against a `CommandBuilder` once drained
        # @return [Array<Array>] every pending command queued so far, this one last
        def command_impl(name, from: nil, &block)
          # Owner is stamped once `Aggregate#initialize` runs; an entity's own commands are
          # owned by the entity instead.
          @pending_commands << [name, from, block]
        end

        private

        # Deferred: entity/command/query queue a descriptor instead of building eagerly, so a
        # later-declared piece can still be referenced from an earlier line. Entities drain
        # first and fully — a command's own `sets` may need an entity's attributes already built.
        def drain_pending!
          @entities = @pending_entities.map { |name, block| build_entity(name, block) }
          @commands = @pending_commands.map { |name, from, block| build_command(name, from, block) }
          @queries  = @pending_queries.map do |name, block|
            QueryBuilder.build(name, owner_attributes: attributes, &block)
          end
        end

        def build_entity(name, block)
          EntityBuilder.build(name, owner_value_objects:             @value_objects + closed_sets,
                                    owner_named_givens:              @entity_named_givens,
                                    identity_name_prefix:            "#{Naming.demodulise(@name)}#{Naming.demodulise(name)}",
                                    identity_value_object_installer: ->(value_object) { @value_objects << value_object },
                                    aggregate_name:                  @name,
                                    chapter_entity_named_givens:     @chapter_entity_named_givens,
                                    chapter_entity_pending_givens:   @chapter_entity_pending_givens,
                              &block)
        end

        def build_command(name, from, block)
          CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                     owner_attributes: attributes,
                                     owner_constructs: @value_objects + closed_sets + @entities, &block)
        end
      end
    end
  end
end
