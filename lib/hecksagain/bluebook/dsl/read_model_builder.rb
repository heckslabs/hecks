module Hecksagain
  module Bluebook
    module DSL
      class ReadModelBuilder
        include QuerySpecification::Common::DSL

        def initialize(name)
          @name = name
        end

        def description(value)
          # moved to the language: ProjectionText / purpose, on Projection.Declare
          @description = value
        end

        def use_index(name)
          @index_hints ||= []
          @index_hints << QuerySpecification::Common::IndexHint.new(name: name)
        end

        def reference_to(type, as: nil)
          raise Malformed, "#{@name} already has a projection reference" if @reference_target
          @reference_target = Naming.demodulise(type)
          @reference_name   = (as || Naming.snake(@reference_target)).to_sym
        end

        # Order-independent. `many:` is decided by comparing the included type
        # against the reference target, so this used to REFUSE an include
        # declared before the reference — a rule guarding an implementation
        # limitation rather than a truth about read models. The includes are
        # collected raw and resolved at build, when the reference is known, so
        # there is no rule left to enforce.
        def include(type, as: nil)
          @includes ||= []
          @includes << [Naming.demodulise(type), as]
        end

        # NAMES which of the eligible head's own fields to nest its rows
        # under — one level per field, the leaf being that row with the
        # named fields removed (they're already spent, as the keys that
        # reached it). The same "exactly one many-side head" rule
        # `seal_query_options` already enforces for where/order_by/etc
        # applies here too (`seal_group_by`) — grouping is a question
        # about ONE collection's own rows, same as those are.
        def group_by(*fields)
          # Hash rows, `{field:}`, not bare symbols — same shape
          # `aggregate_heads` already uses for exactly the reason it
          # does: the language's own self-hosted grammar (`projection
          # .bluebook`'s `GroupByField`) has to have SOMETHING to read a
          # `field:` off of when `Judge` walks this list generically: a
          # bare `Symbol` has no attribute of its own to read.
          @group_by = fields.map { |field| { field: field.to_sym } }
        end

        # `reference_to` is now OPTIONAL — a read model with no root is a
        # BULK one: every `include`d head reads its own aggregate whole
        # (no FK match against a root that doesn't exist), and dispatch
        # takes no id argument at all. This used to be REQUIRED, on the
        # assumption a read model was always "one root record's own
        # cross-aggregate view" — true of every real corpus report so
        # far, but not a truth about read models themselves: `group_by`'s
        # own real use (nesting an aggregate's OWN whole table by its own
        # field values) has no root to speak of. Still needs to describe
        # SOMETHING — zero includes AND no reference is refused.
        def build
          raise Malformed, "#{@name} needs an aggregate-head reference or at least one include" if !@reference_target && Array(@includes).empty?

          Array(@includes).each do |target, as|
            add_aggregate_head(target, as, many: target != @reference_target)
          end
          seal_query_options
          seal_group_by
          seal_cursor
          ReadModel.new(name: @name, description: @description, reference_name: @reference_name,
                            reference_target: @reference_target, aggregate_heads: @aggregate_heads || [],
                            wheres: @wheres || [], order_by: @order_by, limit: @limit, offset: @offset,
                            cursor: @cursor, consistency: @consistency, freshness: @freshness,
                            authorization: @authorization, null_semantics: @null_semantics,
                            inspection: @inspection, group_by: @group_by || [],
                            index_hints: @index_hints || [])
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # where/order_by/limit/offset/authorize's tenant all apply to exactly
        # one collection — the single `include`d aggregate whose head is
        # "many" (the "one" side, the reference target itself, is a single
        # row; ordering, paging, or tenant-scoping one row means nothing). A
        # read model with zero many-heads has nothing for them to filter ;
        # one with several has no way to say WHICH of several unrelated
        # collections a caller meant — so both refuse here rather than
        # silently applying to an arbitrary one. `authorize`'s tenant counts
        # here too — TenantScope enforces it against this same head, so an
        # ambiguous target is exactly as unusable as it is for the others.
        def seal_query_options
          declared = @wheres&.any? || @order_by || @limit || @offset || @authorization&.tenant
          return unless declared

          many = Array(@aggregate_heads).count { |head| head[:many] }
          return if many == 1

          raise Malformed,
                "#{@name} declares where/order_by/limit/offset but includes #{many} many-side " \
                "aggregates, not exactly one — these options apply to a single collection; " \
                "name which one by including only it, or drop the options"
        end

        # Same shape as `seal_query_options`, same reason — `group_by`
        # answers a question about ONE collection's own rows, so zero or
        # several many-side heads leaves it with no unambiguous target.
        def seal_group_by
          return unless @group_by&.any?

          many = Array(@aggregate_heads).count { |head| head[:many] }
          return if many == 1

          raise Malformed,
                "#{@name} declares group_by but includes #{many} many-side " \
                "aggregates, not exactly one — group_by nests a single collection's " \
                "own rows; name which one by including only it"
        end

        # `cursor` parses, round-trips through the IR, and is read by nothing —
        # no interpreter (Memory, Sqlite, Postgres) ever applies it. Refusing
        # it here, rather than deleting the word, keeps the declared syntax
        # honest (the language still knows the shape) while refusing to let a
        # bluebook author believe cursor-based pagination actually happens.
        def seal_cursor
          return unless @cursor

          raise Malformed,
                "#{@name} declares cursor, but no interpreter implements cursor " \
                "pagination — use limit/offset instead"
        end

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
