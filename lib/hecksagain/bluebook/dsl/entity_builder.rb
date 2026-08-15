module Hecksagain
  module Bluebook
    module DSL
      class EntityBuilder
        include AttributeCollector

        def initialize(name, owner_value_objects: [])
          @name     = name
          @commands = []
          @queries  = []
          @owner_value_objects = owner_value_objects
        end

        def description(value) = @description = value

        # THE SAME FIELD AggregateBuilder's OWN reference_to BUILDS — a
        # piece can hold a reference to another root exactly the way its
        # own head can (Card.assignee_id, a Team's own id), just never
        # to another PIECE, since there's no cross-piece addressing
        # anywhere in this language to resolve one against.
        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          attribute(as || default_reference_name(target), Reference.new(target))
        end

        # A PIECE is known by a field, not by a whole value object.
        # `identified_by :sequence` names the SCALAR inside it, which is
        # what an id actually is — a LedgerEntry is entry 3, not entry
        # {"value":3}. See `AggregateBuilder#identified_by`'s own comment —
        # the two constructs cannot drift apart in how they spell an
        # identity, including composite (`identified_by :branch_code,
        # :box_number`), which a piece may declare for the same reason a
        # head may.
        def identified_by(*targets, as: nil, &path)
          return legacy_identified_by(targets.first, as: as, &path) if MetaValidator.shadow_parsing?

          raise Malformed,
                "#{@name}.identified_by no longer takes a block — write identified_by :field, " \
                "or identified_by :field_one, :field_two for a composite identity" if path
          raise Malformed, "#{@name}.identified_by names no field" if targets.empty?

          # See AggregateBuilder#identified_by's own comment — both forms
          # arrive as plain Symbols/ScopedConstants here; distinguished by
          # case the same way the rest of the language already does
          # (PascalCase type, snake_case field).
          if targets.size == 1 && targets.first.to_s[0] =~ /[A-Z]/
            field = as || Naming.snake(targets.first)
            raise Malformed,
                  "#{@name}.identified_by no longer takes a value object — declare the attribute " \
                  "first (attribute :#{field}, #{targets.first}) and write identified_by :#{field}"
          end

          raise Malformed, "#{@name}.identified_by takes no as: — name the declared field itself" if as

          @identity_fields_pending = targets
        end

        def command(name, &block)
          @commands << CommandBuilder.build(name, owner: @name, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, owner_attributes: attributes, &block)
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def build
          resolve_pending_identity!
          Entity.declare(
            name:          @name,
            description:   @description,
            identified_by: @identity_paths,
            attributes:    attributes,
            commands:      @commands,
            queries:       @queries,
            lifecycle:     @lifecycle
          )
        end

        def self.build(name, owner_value_objects: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def resolve_pending_identity!
          if @identity_type_pending
            type, as, insert_at = @identity_type_pending
            @identity_paths = resolve_identity_type!(type, as, insert_at, @owner_value_objects, @name)
          elsif @identity_field_pending
            @identity_paths = resolve_identity_field!(@identity_field_pending, @owner_value_objects, @name)
          elsif @identity_fields_pending
            @identity_paths = @identity_fields_pending.flat_map do |field|
              resolve_identity_field!(field, @owner_value_objects, @name)
            end
          end
        end

        # LEGACY — see AggregateBuilder#legacy_identified_by's own
        # comment; byte-identical shape, one level down.
        def legacy_identified_by(target, as:, &path)
          if target
            raise Malformed, "#{@name}.identified_by takes a field name/value object or a block, not both" if path

            if target.to_s[0] =~ /[A-Z]/
              @identity_type_pending = [target, as, attributes.size]
            else
              raise Malformed, "#{@name}.identified_by :#{target} takes no as: — as: only applies to identified_by ValueObject" if as

              @identity_field_pending = target
            end
            return
          end

          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split(" ").reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end
      end
    end
  end
end
