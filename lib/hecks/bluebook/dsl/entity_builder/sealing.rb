module Hecks
  module Bluebook
    module DSL
      class EntityBuilder
        # The build-time work of a piece: building what was queued, installing synthesized closed
        # sets, and refusing commands that disagree with the piece's lifecycle.
        module Sealing
          private

          # A piece's own `one_of` synthesizes a closed-set value object, installed onto the
          # owning aggregate so the runtime has it to admit against — not just on the attribute.
          # Two sibling pieces synthesizing the same name install it once; a name collision with
          # a different member list is refused rather than silently kept.
          def install_closed_sets!
            return unless @identity_value_object_installer

            closed_sets.each { |value_object| install_closed_set(value_object) }
          end

          def install_closed_set(value_object)
            existing = @owner_value_objects.find { |candidate| candidate.hecks_name == value_object.hecks_name }
            return @identity_value_object_installer.call(value_object) unless existing
            return if existing.to_h == value_object.to_h

            raise Malformed,
                  "#{@name}'s one_of synthesizes #{value_object.hecks_name.inspect}, but the aggregate already " \
                  "holds a different #{value_object.hecks_name.inspect} — name the closed set's field differently"
          end

          # Entities are built first, fully, so a nested command's own `append:` can read a
          # sibling piece's `.attributes`; then commands, then queries.
          def drain_pending!
            @entities = @pending_entities.map { |name, block| build_nested_entity(name, block) }
            @commands = @pending_commands.map { |name, from, block| build_command(name, from, block) }
            @queries  = @pending_queries.map do |name, block|
              QueryBuilder.build(name, owner_attributes: attributes, &block)
            end
          end

          def build_nested_entity(name, block)
            EntityBuilder.build(name, owner_value_objects:             @owner_value_objects,
                                      owner_named_givens:              @owner_named_givens,
                                      identity_name_prefix:            "#{@identity_name_prefix}#{Naming.demodulise(name)}",
                                      identity_value_object_installer: @identity_value_object_installer,
                                      aggregate_name:                  @aggregate_name,
                                      chapter_entity_named_givens:     @chapter_entity_named_givens,
                                      chapter_entity_pending_givens:   @chapter_entity_pending_givens,
                                &block)
          end

          def build_command(name, from, block)
            CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                       owner_attributes: attributes,
                                       owner_constructs: @owner_value_objects + @entities,
                                       entity_shared_givens: @owner_named_givens, &block)
          end

          # Refuses a command that sets the lifecycle field directly, or guards `from:` with no
          # lifecycle declared — a lifecycle field only moves by transition.
          def seal_lifecycle_guards
            @commands.each do |command|
              refuse_lifecycle_field_write!(command) if @lifecycle && !MetaValidator.shadow_parsing?
              refuse_guard_without_lifecycle!(command)
            end
          end

          def refuse_lifecycle_field_write!(command)
            mutation = command.mutations.find { |candidate| writes_lifecycle_field?(candidate) }
            return unless mutation

            raise Malformed,
                  "#{@name}.#{command.hecks_name} sets #{mutation.target}, #{@name}'s lifecycle field — " \
                  "a lifecycle field moves only by transition; declare one instead of setting it"
          end

          # `delegate`/`corrects` are exempt — the frozen-era-text case, not a live mutation.
          def writes_lifecycle_field?(mutation)
            ![:delegate, :corrects].include?(mutation.op) && mutation.target.to_sym == @lifecycle.field.to_sym
          end

          def refuse_guard_without_lifecycle!(command)
            return unless command.from
            return if @lifecycle

            raise Malformed,
                  "#{@name}.#{command.hecks_name} guards from: #{Array(command.from).inspect}, but " \
                  "#{@name} declares no lifecycle — from: checks a lifecycle field, and there is " \
                  "none here to check"
          end
        end
      end
    end
  end
end
