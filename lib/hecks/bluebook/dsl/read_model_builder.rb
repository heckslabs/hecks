require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `read_model "Name" do ... end` block into a `ReadModel` — a
      # cross-aggregate projection built from an optional `reference_to`
      # root (omitted, it's a rootless "bulk" read model) plus one or more
      # `include`d aggregate heads, with `where`/`order_by`/`limit`/etc, and
      # at most one of `group_by`, `count`, or `median` as its single
      # reduction over the one eligible many-side collection.
      class ReadModelBuilder
        GRAMMAR_CONTEXT = "ReadModel".freeze

        include QuerySpecification::Common::DSL
        include WordGate

        def initialize(name)
          @name = name
        end

        def description(value)
          # moved to the language: ProjectionText / purpose, on Projection.Declare
          @description = value
        end

        # RENAMED FROM `reference_to` — item #13's full metaprogrammed
        # dispatch (slice 4b). Bootstrap-reachable, in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def reference_to_impl(type, as: nil)
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
        # RENAMED FROM `include`/`group_by` — item #13's full
        # metaprogrammed dispatch (slice 4c). `include` IS bootstrap-
        # reachable (every core chapter's own `read_model` names which
        # aggregates it includes with it — a first grep dismissed this
        # as `Module#include` noise and was wrong; the cold-boot test
        # after this rename caught it directly), so it's in
        # BOOTSTRAP_CALLS_FALLBACK; `group_by` is not (no core read_model
        # groups). The class-level `include WordGate` this file's own
        # class body uses is `Module#include`, a different receiver,
        # unaffected by renaming this INSTANCE method either way.
        def include_impl(type, as: nil)
          @includes ||= []
          @includes << [Naming.demodulise(type), as]
        end

        # `on:` (ADR 0055) — OVERRIDES of `QuerySpecification::Common::DSL`'s
        # shared `where_impl`/`order_by_impl`/`limit_impl`/`offset_impl`,
        # scoped to `ReadModelBuilder` alone rather than added to the shared
        # module `Query` also mixes in: a plain `query` has no
        # `aggregate_heads` at all, so `on:` there would be a silently-
        # ignored no-op rather than a real answer. Overriding only here
        # means a `Query`'s own `where(..., on: X)` gets Ruby's own loud
        # `unknown keyword: :on` instead of quietly doing nothing.
        #
        # `on:` names the target by TYPE (`on: Character`), resolved the
        # same way `reference_to`/`include` already resolve their own type
        # argument (`Naming.demodulise`) — not by the include's own `as:`
        # alias. A read model that `include`s the SAME type twice under two
        # different `as:` has no way to say which one `on:` means today; no
        # real corpus read model does this, so it's a real, deliberate scope
        # limit (see ADR 0055), not an oversight.
        #
        # `*positional, on:, **rest` rather than a plain `(clauses, on: nil)`
        # — found necessary, not stylistic, by reproducing the failure
        # directly: `where(status: "disputed")` reaches here with its
        # `status: "disputed"` captured as `**kwargs` (GenericDispatch's own
        # `builder.send(calls, *args, **kwargs, &block)`), and Ruby stops
        # auto-converting a bare `**hash` call into a plain positional Hash
        # THE MOMENT a method declares any real keyword parameter — so a
        # `(clauses, on: nil)` signature raised "wrong number of arguments
        # (given 0, expected 1)" on every ordinary `where(field: value)`
        # call, never reaching `on:` at all. `**rest` sidesteps this: Ruby
        # still auto-splits `on:` into the declared keyword and gathers
        # every OTHER key into `rest` regardless of how the caller wrote it.
        #
        # `QuerySpecification::Common::WhereClause` etc — FULLY QUALIFIED,
        # not the bare names `dsl.rb`'s own shared `where_impl` gets away
        # with. That file is lexically nested inside `Common` itself, so
        # `WhereClause` resolves directly; this class is nested inside
        # `Bluebook::DSL`, which has no lexical or ancestor path to
        # `QuerySpecification::Common` at all — a bare `WhereClause` here
        # falls through to `const_missing` and, mid-bluebook-load, that's
        # `ConstShim`, which resolves it against the self-hosted grammar
        # domain's OWN unrelated `WhereClause` construct instead (a `Module`,
        # not this `Struct`) — found directly by reproducing "undefined
        # method `new' for module WhereClause" against a real corpus load,
        # not guessed.
        def where_impl(*positional, on: nil, **rest)
          raise ArgumentError, "wrong number of arguments (given #{positional.size}, expected 1)" if positional.size > 1

          @wheres ||= []
          target = resolve_target(on)
          clauses = (positional.first || {}).merge(rest)
          clauses.each do |field, value|
            op, operand = split_comparator(value)
            @wheres << QuerySpecification::Common::WhereClause.new(field: field, op: op, value: operand, target: target)
          end
        end

        def order_by_impl(field, direction = :asc, on: nil)
          @order_by = QuerySpecification::Common::OrderBy.new(field: field, direction: direction, target: resolve_target(on))
        end

        def limit_impl(value, on: nil)
          @limit = QuerySpecification::Common::LimitSpec.new(value: value, target: resolve_target(on))
        end

        def offset_impl(value, on: nil)
          @offset = QuerySpecification::Common::OffsetSpec.new(value: value, target: resolve_target(on))
        end

        # NAMES which of the eligible head's own fields to nest its rows
        # under — one level per field, the leaf being that row with the
        # named fields removed (they're already spent, as the keys that
        # reached it). The same "exactly one many-side head" rule
        # `seal_query_options` already enforces for where/order_by/etc
        # applies here too (`seal_group_by`) — grouping is a question
        # about ONE collection's own rows, same as those are.
        def group_by_impl(*fields)
          # Hash rows, `{field:}`, not bare symbols — same shape
          # `aggregate_heads` already uses for exactly the reason it
          # does: the language's own self-hosted grammar (`projection
          # .bluebook`'s `GroupByField`) has to have SOMETHING to read a
          # `field:` off of when `Judge` walks this list generically: a
          # bare `Symbol` has no attribute of its own to read.
          @group_by = fields.map { |field| { field: field.to_sym } }
        end

        # `count` -- a bare row count over the eligible many-side head's
        # own rows (after `where`/`order_by`/`limit`/`offset` apply, the
        # same rows `group_by` itself would nest) -- ANSWERS "how many
        # match", not "which ones". A sibling REDUCTION to `group_by`,
        # not a filter: `seal_aggregation` refuses combining it with
        # `group_by` or with `median`, the same "exactly one many-side
        # head" rule `seal_group_by` already enforces for the same
        # reason -- a bare marker, so `@count` is left unset (nil, not
        # false) rather than defaulted, matching the "ABSENT is not
        # EMPTY" reading `Lifecycle`'s own optional fields already rely
        # on for the Judge's setter dispatch (Behaviour::ReadModel#
        # count?, ReadModelInterpreter#aggregation_target).
        # `count` — item #13's full metaprogrammed dispatch, slice 1
        # (whole-project table-unification survey): the ONLY Keyword row
        # filling `count` — a bare marker, now stored as literal `true`
        # by `GenericDispatch` off that same table fact.

        # `median(field)` -- the median VALUE of one numeric field
        # across the eligible many-side head's own rows. EVEN COUNT: the
        # average of its two middle values (the standard definition,
        # not "the lower of the two") -- see
        # Runtime::ReadModelInterpreter#median for where that lands and
        # is documented for a caller. `field` must name a numeric
        # attribute (a bare numeric primitive, or a value object
        # carrying one) -- checked once, at read time, by
        # ReadModelInterpreter#aggregation_target, the same place
        # `group_by`'s own field names are checked.
        # `median` — item #13's full metaprogrammed dispatch, slice 1:
        # same shape as `count`, above (a bare, kind-driven coerce-and-
        # assign).

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
          if !@reference_target && Array(@includes).empty?
            raise Malformed,
                  "#{@name} needs an aggregate-head reference or at least one include"
          end

          Array(@includes).each do |target, as|
            add_aggregate_head(target, as, many: target != @reference_target)
          end
          seal_query_options
          seal_group_by
          seal_aggregation
          seal_cursor
          ReadModel.new(name: @name, description: @description, reference_name: @reference_name,
                        reference_target: @reference_target, aggregate_heads: @aggregate_heads || [],
                        wheres: @wheres || [], order_by: @order_by, limit: @limit, offset: @offset,
                        cursor: @cursor,
                        authorization: @authorization, null_semantics: @null_semantics,
                        inspection: @inspection, group_by: @group_by || [],
                        count: @count, median_field: @median_field)
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # where/order_by/limit/offset/authorize's tenant all apply to
        # collections — the `include`d aggregates whose heads are "many"
        # (the "one" side, the reference target itself, is a single row;
        # ordering, paging, or tenant-scoping one row means nothing). ADR
        # 0055 gave `where`/`order_by`/`limit`/`offset` an `on:` to name
        # WHICH many-side collection they mean, so this asks two questions
        # now instead of one:
        #
        #   1. Does every declared `on:` actually name a many-side included
        #      aggregate? Checked regardless of how many many-side heads
        #      exist — a typo refuses immediately, not only once ambiguity
        #      would otherwise bite.
        #   2. Is there still an UNTARGETED option declared (including
        #      `authorize`'s own `tenant:`, which has no `on:` of its own —
        #      a real, deliberate scope limit, see ADR 0055)? An untargeted
        #      option still needs exactly one many-side head to mean
        #      anything unambiguous — the ORIGINAL rule, unchanged, and
        #      still worded the same way (`spec/runtime/
        #      read_model_interpreter_spec.rb`'s existing refusal regex
        #      still matches).
        #
        # A read model with several many-side heads is legal precisely when
        # every declared option names one; a read model with a single
        # many-side head is unaffected either way, `on:` or not.
        def seal_query_options
          many = Array(@aggregate_heads).select { |head| head[:many] }

          validate_declared_targets!(many)
          return unless untargeted_option_declared?
          return if many.size == 1

          raise Malformed,
                "#{@name} declares where/order_by/limit/offset but includes #{many.size} many-side " \
                "aggregates, not exactly one — these options apply to a single collection; " \
                "name which one with `on:` (e.g. `where(field: value, on: Character)`), or drop the options"
        end

        # Question 1 of `seal_query_options`'s own two, split out to keep
        # both under the same "one job per method" shape every OTHER seal in
        # this file already holds to (each raises its own one Malformed, for
        # its own one reason).
        def validate_declared_targets!(many)
          many_by_aggregate = many.to_h { |head| [head[:aggregate], head] }
          declared_targets = Array(@wheres).map(&:target) + [@order_by&.target, @limit&.target, @offset&.target]

          declared_targets.compact.uniq.each do |target|
            next if many_by_aggregate.key?(target)

            raise Malformed,
                  "#{@name}'s `on: #{target}` doesn't name one of its own many-side included " \
                  "aggregates (it includes #{many.map { |head| head[:aggregate] }.join(', ')} as " \
                  "many-side heads)"
          end
        end

        # Question 2 of `seal_query_options`'s own two — see that method's
        # header. `authorize`'s own `tenant:` has no `on:` at all (ADR 0055's
        # own documented scope limit), so it always counts as untargeted.
        def untargeted_option_declared?
          Array(@wheres).any? { |where| where.target.nil? } ||
            (@order_by && @order_by.target.nil?) ||
            (@limit && @limit.target.nil?) ||
            (@offset && @offset.target.nil?) ||
            @authorization&.tenant
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

        # `count`/`median` are the OTHER two reductions a read model may
        # declare over its one eligible collection — same "exactly one
        # many-side head" rule as `seal_group_by`, plus a rule
        # `seal_group_by` doesn't need: a read model reports ONE shape,
        # so `count` and `median` cannot both be declared, and neither
        # may combine with `group_by` (nesting rows and reducing them to
        # a scalar are answers to different questions ; a caller asking
        # "how many, nested by state" is not a shape this read model
        # produces today — a real, deliberate scope limit, not an
        # oversight, the same discipline the rootless model's own
        # "each head reads independently" limit already documents).
        def seal_aggregation
          return unless @count || @median_field

          if @count && @median_field
            raise Malformed,
                  "#{@name} declares both count and median — a read model reports " \
                  "one shape; choose one"
          end
          if @group_by&.any?
            raise Malformed,
                  "#{@name} declares count/median together with group_by — a read " \
                  "model reports one shape; choose one"
          end

          many = Array(@aggregate_heads).count { |head| head[:many] }
          return if many == 1

          raise Malformed,
                "#{@name} declares count/median but includes #{many} many-side " \
                "aggregates, not exactly one — count/median reduce a single " \
                "collection's own rows; name which one by including only it"
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

        # `on:`'s own resolution (ADR 0055) — same demodulise `reference_to`/
        # `include` already use for their own type argument. `nil` when `on:`
        # is omitted, matching every other optional field's "absent, not
        # false" reading in this file.
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
