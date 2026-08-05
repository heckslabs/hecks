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

        def build
          raise Malformed, "#{@name} needs an aggregate-head reference" unless @reference_target

          Array(@includes).each do |target, as|
            add_aggregate_head(target, as, many: target != @reference_target)
          end
          seal_query_options
          seal_cursor
          IR::ReadModel.new(name: @name, description: @description, reference_name: @reference_name,
                            reference_target: @reference_target, aggregate_heads: @aggregate_heads || [],
                            wheres: @wheres || [], order_by: @order_by, limit: @limit, offset: @offset,
                            cursor: @cursor, consistency: @consistency, freshness: @freshness,
                            authorization: @authorization, null_semantics: @null_semantics,
                            inspection: @inspection,
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
