require_relative "word_gate"
require_relative "read_model_builder/sealing"
module Hecks
  module Bluebook
    module DSL
      # Parses a `read_model "Name" do ... end` block into a `ReadModel`: a cross-aggregate
      # projection over an optional `reference_to` root and its `include`d aggregate heads.
      class ReadModelBuilder
        GRAMMAR_CONTEXT = "ReadModel".freeze

        include QuerySpecification::Common::DSL
        include WordGate
        include Sealing

        # @param name [String] the read model's own name, as written after `read_model`
        def initialize(name)
          @name = name
        end

        # Sets the human-readable description shown for this read model.
        #
        # @param value [String] the description text
        # @return [String] the description as stored
        def description(value)
          @description = value
        end

        # Declares the read model's own "one" side, the aggregate head every row projects around.
        #
        # @param type [Module, Symbol, String] the referenced aggregate, written as a bare
        #   constant
        # @param as [Symbol, nil] the field name to project the reference under; `nil` derives it
        #   from the target's own name
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `reference_to` was already declared
        def reference_to_impl(type, as: nil)
          raise Malformed, "#{@name} already has a projection reference" if @reference_target

          @reference_target = Naming.demodulise(type)
          @reference_name   = (as || Naming.snake(@reference_target)).to_sym
        end

        # Adds one aggregate head this read model projects.
        #
        # `many:` is decided at build time against the reference target, so an include declared
        # before `reference_to` resolves like one declared after it.
        #
        # @param type [Module, Symbol, String] the included aggregate, written as a bare constant
        # @param as [Symbol, nil] the field name to project this head's rows under; `nil` derives
        #   it from the target's own name (pluralized for a many-side head)
        # @return [void]
        def include_impl(type, as: nil)
          @includes ||= []
          @includes << [Naming.demodulise(type), as]
        end

        # The `on:` overrides of the shared where/order_by/limit/offset are kept off the shared
        # module so a plain `query` still raises `unknown keyword: :on`. `on:` names its target
        # by type, not by an include's `as:` alias (ADR 0055).

        # Records one `WhereClause` per `field => value` pair, optionally targeted with `on:`.
        #
        # @param positional [Array<Hash>] at most one bare Hash of clauses; normally empty
        # @param on [Module, Symbol, String, nil] the many-side include the clauses apply to
        # @param rest [Hash{Symbol => Object}] `field => value`; a value is a literal, a Symbol
        #   naming a query argument, or a one-pair `{ comparator => operand }` Hash
        # @return [void]
        # @raise [ArgumentError] on more than one positional argument or a malformed comparator
        def where_impl(*positional, on: nil, **rest)
          # `**rest` because a declared keyword stops Ruby turning a bare `where(status: "x")`
          # into a positional Hash.
          raise ArgumentError, "wrong number of arguments (given #{positional.size}, expected 1)" if positional.size > 1

          @wheres ||= []
          target = resolve_target(on)
          clauses = (positional.first || {}).merge(rest)
          clauses.each { |field, value| @wheres << where_clause(field, value, target) }
        end

        # Records the read model's single ordering, replacing any declared earlier.
        #
        # @param field [Symbol, String] the field to order by; a dotted path such as
        #   `:"order.value"` reaches a value object's member
        # @param direction [Symbol, String] `:asc` or `:desc`
        # @param on [Module, Symbol, String, nil] the many-side included aggregate this ordering
        #   applies to; `nil` when this read model has at most one many-side head
        # @return [QuerySpecification::Common::OrderBy] the ordering just recorded
        def order_by_impl(field, direction = :asc, on: nil)
          @order_by = QuerySpecification::Common::OrderBy.new(field: field, direction: direction, target: resolve_target(on))
        end

        # Records the most rows the targeted collection returns.
        #
        # @param value [Integer, Symbol] a literal row count, or a Symbol naming the query
        #   argument that supplies it
        # @param on [Module, Symbol, String, nil] the many-side included aggregate this limit
        #   applies to; `nil` when this read model has at most one many-side head
        # @return [QuerySpecification::Common::LimitSpec] the limit just recorded
        def limit_impl(value, on: nil)
          @limit = QuerySpecification::Common::LimitSpec.new(value: value, target: resolve_target(on))
        end

        # Records how many matched rows the targeted collection skips before the limit applies.
        #
        # @param value [Integer, Symbol] a literal row count, or a Symbol naming the query
        #   argument that supplies it
        # @param on [Module, Symbol, String, nil] the many-side included aggregate this offset
        #   applies to; `nil` when this read model has at most one many-side head
        # @return [QuerySpecification::Common::OffsetSpec] the offset just recorded
        def offset_impl(value, on: nil)
          @offset = QuerySpecification::Common::OffsetSpec.new(value: value, target: resolve_target(on))
        end

        # Names which of the eligible head's own fields to nest its rows under, one level per
        # field; the leaf is the row with those fields removed.
        #
        # @param fields [Array<Symbol>] the eligible many-side head's own fields to nest its rows
        #   under, one level per field
        # @return [void]
        def group_by_impl(*fields)
          # Hash rows rather than bare symbols: the self-hosted `GroupByField` grammar reads
          # `field:` off each entry when `Judge` walks the list.
          @group_by = fields.map { |field| { field: field.to_sym } }
        end

        # `sum`/`avg`/`min`/`max`/`any`/`all` need no method of their own: each is one
        # required positional symbol, the same shape as `median`, which `GenericDispatch`
        # already handles generically off the grammar table (ADR 0078).

        # The field's value at one interpolated rank (`0.0`..`1.0`) across the eligible
        # many-side head's own rows; `median` is the fixed `at: 0.5` case (ADR 0078). Takes
        # a named argument alongside its field, which is outside `GenericDispatch`'s
        # one-positional-argument shape, so it needs a method of its own.
        #
        # @param field [Symbol] the eligible many-side head's own numeric field
        # @param at [Float] the rank to interpolate, `0.0` (the minimum) through `1.0` (the maximum)
        # @return [void]
        # @raise [ArgumentError] if `at` is not a `Float` in `0.0..1.0`
        def percentile_impl(field, at:)
          unless at.is_a?(Float) && (0.0..1.0).cover?(at)
            raise ArgumentError, "percentile's at: must be a Float between 0.0 and 1.0 (given #{at.inspect})"
          end

          @percentile_field = field.to_sym
          @percentile_at = at
        end

        # Assembles the declared references, includes and clauses into a `ReadModel`, after
        # validating them.
        #
        # `reference_to` is optional: a rootless read model is a bulk one and takes no id.
        # Zero includes and no reference is refused.
        # @return [Bluebook::ReadModel] the built read model
        # @raise [Bluebook::DSL::Malformed] if neither `reference_to` nor any `include` is
        #   declared, if `where`/`order_by`/`limit`/`offset`/`group_by` or a reduction name an
        #   `on:` that isn't a many-side include or are left untargeted with more than one
        #   many-side head, if more than one reduction is declared or one is combined with
        #   `group_by`, or if `cursor` is declared
        def build
          if !@reference_target && Array(@includes).empty?
            raise Malformed,
                  "#{@name} needs an aggregate-head reference or at least one include"
          end

          Array(@includes).each do |target, as|
            add_aggregate_head(target, as, many: target != @reference_target)
          end
          seal_all
          ReadModel.new(**projection_fields, **filtering_fields, **reduction_fields)
        end

        # Evaluates a `read_model` block against a fresh builder and returns what it built.
        #
        # @param name [String] the read model's own name
        # @yield the read model's body, `instance_eval`'d against a new builder
        # @return [Bluebook::ReadModel] the built read model
        # @raise [Bluebook::DSL::Malformed] see `#build`
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # The read model's name, reference and the heads it projects.
        def projection_fields
          { name: @name, description: @description, reference_name: @reference_name,
            reference_target: @reference_target, aggregate_heads: @aggregate_heads || [] }
        end

        # The clauses, ordering and paging that narrow what the read model returns.
        def filtering_fields
          { wheres: @wheres || [], order_by: @order_by, limit: @limit, offset: @offset, cursor: @cursor,
            authorization: @authorization, null_semantics: @null_semantics,
            inspection: @inspection, group_by: @group_by || [] }
        end

        # The one reduction, if any, the read model reports in place of rows.
        def reduction_fields
          { count: @count, median_field: @median_field,
            sum_field: @sum_field, avg_field: @avg_field, min_field: @min_field,
            max_field: @max_field, percentile_field: @percentile_field,
            percentile_at: @percentile_at, any_field: @any_field, all_field: @all_field }
        end

        # Fully qualified: a bare `WhereClause` reaches `ConstShim` and resolves to the
        # grammar domain's unrelated module.
        def where_clause(field, value, target)
          op, operand = split_comparator(value)
          QuerySpecification::Common::WhereClause.new(field: field, op: op, value: operand, target: target)
        end

        # Resolves `on:` to a type name; `nil` when omitted.
        def resolve_target(on) = on && Naming.demodulise(on)

        def add_aggregate_head(type, name, many:)
          @aggregate_heads ||= []
          target = Naming.demodulise(type)
          output = (name || (many ? Naming.plural(Naming.snake(target)) : Naming.snake(target))).to_sym
          raise Malformed, "#{@name} already projects #{output}" if @aggregate_heads.any? { |head| head[:as] == output }

          @aggregate_heads << { aggregate: target, as: output, many: many }
        end
      end
    end
  end
end
