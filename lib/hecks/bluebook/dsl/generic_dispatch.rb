require_relative "bootstrap_table"

module Hecks
  module Bluebook
    module DSL
      # Item #13's full metaprogrammed dispatch — slices 1-2 of 4, whole-
      # project table-unification survey. WordGate (the first slice,
      # already shipped) only checks a word's admissibility; this module
      # executes the safe, mechanical subset of what a word actually
      # does, read live off the same self-hosted grammar table — so a
      # builder method for one of these words no longer needs to be
      # hand-written at all. Called from `WordGate#method_missing`'s own
      # "admitted here, no builder method for it yet" branch, so it only
      # ever sees a word whose (context, word) pair the grammar already
      # admits.
      #
      # Scope, deliberately narrow and verified word-by-word — a full
      # audit read every real Ruby builder method's own source before
      # any of this was written, not inferred from the table's shape
      # alone (which fooled a first pass: `ReadModelBuilder#group_by`/
      # `#include` look like plain fills from `kind`/`fills` alone, but
      # actually wrap their arguments in a Hash/tuple). What's covered:
      #
      #   - a single, non-variadic, positional Argument row whose value
      #     is stored with nothing beyond a uniform, kind-driven
      #     coercion (`COERCE_BY_KIND`) — or, for `kind: "text"`, no
      #     coercion at all when the row's own `coerce: "false"` says so
      #     (six real, audited exceptions: `.to_s` on an actual String
      #     is a same-object no-op for every real corpus use, but a
      #     genuine behavior change for a direct Ruby API call passing
      #     something else)
      #   - a scalar assign (`@ivar = value`) or list append (`@ivar <<
      #     value`), chosen by whether the ivar `fills:` names is
      #     already an Array at call time (every candidate's own
      #     `initialize` pre-populates its accumulating ivars as `[]` —
      #     read live, not assumed)
      #   - a zero-argument word, either (a) one of several sibling
      #     Keyword rows in the same context sharing the same `fills:`
      #     target — derives its own stored value from its own word
      #     name as a symbol (`core`/`generic`/`supporting` all fill
      #     `classification`), or (b) the only Keyword row filling its
      #     own `fills:` target — a bare marker, stores literal `true`
      #     (`ReadModel#count`)
      #   - an OPENS_BLOCK word named in `SAFE_OPENS_BLOCK` below,
      #     verified to do nothing beyond "build the child, instance_
      #     eval the block against it, append the result" — see that
      #     constant's own comment
      #   - (slice 2) a single-fill word whose row also names a `blank_
      #     message:` — raises that exact Malformed text if the coerced
      #     value is blank, before storing it, matching a real hand-
      #     written guard exactly (`Translation#retired`/
      #     `TranslationAggregate#drop`, the only two words in the whole
      #     grammar with this precise shape — `required: "true"` alone
      #     only gates Ruby's own arity, never a present-but-blank
      #     value, and most `required: "true"` words do not raise on
      #     blank, so this needed a real per-row signal, not an
      #     assumption from `required:` alone)
      #
      # Explicitly out of this slice (found live, during the audit, not
      # assumed) — stays hand-written, unaffected, until a later slice's
      # own new table columns (`gated_by:`/`calls:`) can name
      # what it really does: variadic accumulation with a real transform
      # (`attaches_to`); source-block extraction (`ensures`, `where`);
      # Struct/Hash-wrapping (`limit`, `group_by`, `rekey`); a guard
      # clause not reducible to a plain blank-check (`role`'s own "raise
      # if already set" uniqueness gate — a genuinely different shape
      # from `retired`/`drop`'s own blank-check, needing its own
      # design); a dynamically-built refusal message rather than one
      # fixed string (`TranslationAggregateBuilder#unresolved` — real
      # branching logic choosing between several message shapes, not a
      # simple "always refuses" flag; belongs with `calls:`, slice 4,
      # where a table row can name the real Ruby helper that already
      # builds it); a side effect beyond storage (`uses_framework`,
      # `uses_embryonaut_bluebook`); an opens-block word threading extra
      # constructor args to its child (`asks`/`tells`/`operation`,
      # `Bluebook#aggregate`, `Translation#aggregate`) or doing anything
      # beyond a bare fold after building (`Aggregate#policy`'s stamp,
      # `Aggregate#value_object`'s flatten, `Hecksagon#port`'s resolver-
      # swap-and-branch); the deferred-build queue pattern (`Aggregate`/
      # `Entity`'s own `command`/`entity`/`query`); the shadow_parsing?-
      # gated words (`has_many`/`has_one`/`belongs_to`/`then_set`/
      # `trigger`/`dispatch`/`one_of` — each delegates to its own
      # `legacy_*` method under `MetaValidator.shadow_parsing?`, else
      # refuses; a genuinely different two-branch shape per word, closer
      # to `calls:`'s own territory than a simple fill); and every
      # `File`-context word (routes through `Runtime.current_registry`,
      # a side effect this module has no business performing).
      #
      # Two further, different reasons a word can look table-safe and
      # still be excluded, both found live rather than assumed:
      #   - Bootstrap reachability. `WordGate`'s own gate steps aside
      #     entirely while `MetaValidator.bootstrapping?` (the meta-
      #     domain's own circularity — its grammar table doesn't exist
      #     yet to read), and `load_grammar_into` loads real `.port`/
      #     `.adapter` files, plus every core `.bluebook` chapter, during
      #     that exact window. Any word those files actually call (found
      #     to be nearly every common one — `vision`/`core`/`generic`/
      #     `supporting`/`description`/`goal`/`emits`/`role`/`identified_
      #     by` describe literally every self-hosted aggregate/command)
      #     has no working method to fall back on if its hand-written
      #     `def` is removed — `super` from `WordGate#method_missing`
      #     just raises `NoMethodError`. `PortBuilder`/`AdapterBuilder`/
      #     `BluebookBuilder` turned out to be entirely off-limits to
      #     this slice for exactly this reason, confirmed by cold-
      #     booting `MetaValidator.grammar_registry` after each
      #     candidate removal, not assumed safe from reading the table
      #     alone.
      #   - A conflicting hand-written `method_missing`. `WorldBuilder`
      #     and `HecksagonBuilder` each define their own `method_missing`
      #     directly on the class (for genuinely open-ended settings/
      #     collector verbs) — a method defined directly on a class always
      #     wins over one from an included module in Ruby's own method
      #     resolution, so `WordGate`'s (and this module's) own
      #     `method_missing` never runs for their builders at all. Their
      #     own candidate words (`realm`/`latest`, `subscribe`) stay
      #     hand-written for this structural reason, independent of
      #     whether their own behavior would otherwise qualify.
      module GenericDispatch
        NOT_HANDLED = Object.new.freeze

        COERCE_BY_KIND = { "text" => :to_s, "symbol" => :to_sym }.freeze

        # (context, word) OPENS_BLOCK pairs verified, by reading every
        # real Ruby method, to do nothing beyond building the child and
        # appending it — see this file's own header for the full account
        # of what was excluded and why. Value: the ivar the built child
        # is appended into. Not derivable from `fills:` — every one of
        # these Keyword rows carries `fills: ""`; the append target is
        # implicit in the hand-written code today, never named by the
        # table at all, so this is the one place slice 1 hand-names a
        # fact the table doesn't yet carry, rather than guessing a
        # pluralization rule that would silently mismatch a future word.
        SAFE_OPENS_BLOCK = {
          %w[Bluebook policy]          => :policies,
          %w[Bluebook process_manager] => :process_managers,
          %w[Bluebook read_model]      => :read_models
        }.freeze

        # `WordGate#method_missing`'s own bootstrap-window fallback,
        # consulted only while `MetaValidator.bootstrapping?` (the real
        # table doesn't exist yet to read `keyword[:calls]` from). Names
        # the same (context, word) -> method pairs the real table's own
        # `calls:` column carries — every live row, projected ahead of
        # time into the committed lib/hecks/bluebook/dsl/bootstrap_table.rb
        # (bin/project_bootstrap_table, pinned by spec/bootstrap_table_spec.rb).
        #
        # This used to be a hand-kept subset — 48 of 87 rows, each checked
        # for bootstrap-reachability by grepping the core chapters. Carrying
        # all of them costs nothing: a builder with its own `def` never
        # reaches `method_missing`, and one without gains the same dispatch
        # it gets once bootstrapping ends. `["Type", word]` rows still cover
        # `list_of`/`one_of` in an attribute's type position for every
        # calling context (see `word_gate_dispatch`'s own header).
        BOOTSTRAP_CALLS_FALLBACK = BootstrapTable::CALLS

        module_function

        # **The static predicate** — does this (context, word) pair fall
        # within this slice's own verified scope, without executing
        # anything? The same row-shape checks `try` itself runs before
        # ever touching a real argument, shared so a conformance spec
        # (which has no real call, no real builder instance) can ask the
        # same question `method_missing` answers live.
        def handles?(context, word, rows: MetaValidator::SyntaxBoot.call)
          !shape_for(context, word, rows).nil?
        end

        # `NOT_HANDLED` for anything outside this slice's own verified
        # scope — the caller (`WordGate#method_missing`) falls through
        # to its own existing "not yet implemented" refusal, unchanged,
        # the exact same message a word not yet migrated to any slice
        # already gets today. A real `ArgumentError` — matching what a
        # hand-written method of the same arity would raise — for a
        # call whose shape the grammar admits but whose actual argument
        # count doesn't match; never a silent wrong answer.
        def try(builder, context, word, args, kwargs, block, rows)
          shape = shape_for(context, word, rows)
          return NOT_HANDLED unless shape

          case shape[:kind]
          when :calls_through then try_calls_through(builder, shape[:calls], args, kwargs, block)
          when :opens_block   then try_opens_block(builder, shape[:keyword], args, kwargs, block)
          when :zero_arg      then try_zero_arg(builder, shape[:keyword], args)
          when :single_fill   then try_single_fill(builder, shape[:fills], shape[:argument], args, kwargs)
          else
            # `shape_for` names exactly four kinds and this case
            # matches all four — a backstop against the day a fifth is
            # added there without a matching arm here. Falling through
            # silently would return bare `nil` from what the caller
            # (`WordGate#method_missing`) reads as "handled" (anything
            # other than NOT_HANDLED counts), so a self-hosted DSL word
            # would silently execute as a no-op instead of raising the
            # same "not yet implemented" refusal a genuinely unmigrated
            # word already gets.
            raise Runtime::WiringError,
                  "no dispatcher handles shape #{shape[:kind].inspect} — add one before shape_for can produce it"
          end
        end

        # **The one place row shape is judged** — returns a small Hash naming
        # which of the four safe shapes (context, word) is, or `nil` if
        # it falls outside this slice's own verified scope. No argument
        # values are read here; this only ever looks at the table.
        #
        # An early-return classification chain: each `return` depends on
        # locals (`calls`, `fills`, `arguments`, `arg`) computed by the
        # checks before it. Splitting per shape would mean re-deriving or
        # threading those locals across method boundaries for a
        # classification that is only ever read top-to-bottom once, here.
        # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def shape_for(context, word, rows)
          keyword = rows[:keywords].find { |k| k[:context] == context && k[:word] == word && k[:status] != "retired" }
          return nil unless keyword

          calls = keyword[:calls].to_s
          return { kind: :calls_through, calls: calls } unless calls.empty?

          return { kind: :opens_block, keyword: keyword } if SAFE_OPENS_BLOCK.key?([context, word])

          fills = keyword[:fills].to_s
          return nil if fills.empty?

          arguments = rows[:arguments].select { |a| a[:context] == context && a[:keyword] == word && a[:status] != "retired" }
          return { kind: :zero_arg, keyword: keyword } if arguments.empty?

          return nil unless arguments.size == 1

          arg = arguments.first
          return nil if arg[:variadic] == "true" || arg[:at] != "1" || !arg[:named].to_s.empty?
          return nil unless COERCE_BY_KIND.key?(arg[:kind])

          { kind: :single_fill, fills: fills, argument: arg }
        end

        # `keyword[:calls]` names a real Ruby method whose whole call —
        # every positional, every kwarg, the block, all of it — forwards
        # here unchanged. No argument-shape interpretation at all,
        # deliberately: the target method (`AttributeCollector#
        # attribute_impl`, etc.) already does its own, real, hand-
        # written argument handling; this is a pure, transparent `send`,
        # the lowest-risk possible shape for a word whose own logic is
        # too complex to re-derive from the table (type-quoting refusal,
        # closed-set synthesis, pattern validation, ...).
        def try_calls_through(builder, calls, args, kwargs, block)
          builder.send(calls, *args, **kwargs, &block)
        end

        def try_opens_block(builder, keyword, args, kwargs, block)
          return NOT_HANDLED unless kwargs.empty?

          target_ivar = SAFE_OPENS_BLOCK.fetch([keyword[:context], keyword[:word]])
          child_class = DSL.const_get("#{keyword[:opens]}Builder")

          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1)" unless args.size == 1

          child = child_class.build(args.first, &block)

          ivar = :"@#{target_ivar}"
          list = builder.instance_variable_get(ivar) || builder.instance_variable_set(ivar, [])
          list << child
        end

        def try_zero_arg(builder, keyword, args)
          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0)" unless args.empty?

          rows = MetaValidator::SyntaxBoot.call[:keywords]
          siblings = rows.count do |k|
            k[:context] == keyword[:context] && k[:fills] == keyword[:fills] && k[:status] != "retired"
          end
          value = siblings > 1 ? keyword[:word].to_sym : true

          builder.instance_variable_set(:"@#{keyword[:fills]}", value)
        end

        def try_single_fill(builder, fills, arg, args, kwargs)
          return NOT_HANDLED unless kwargs.empty?

          coerce = COERCE_BY_KIND.fetch(arg[:kind])

          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1)" unless args.size == 1

          value = arg[:coerce] == "false" ? args.first : args.first.public_send(coerce)

          message = arg[:blank_message].to_s
          raise Malformed, message if !message.empty? && value.to_s.empty?

          ivar = :"@#{fills}"
          current = builder.instance_variable_get(ivar)

          if current.is_a?(Array)
            current << value
          else
            builder.instance_variable_set(ivar, value)
          end
        end
      end
    end
  end
end
