module Hecks
  module Fuzzing
    module Properties
      # A DRY RUN LEAVES NO TRACE — `Dispatcher#dry_run?`'s whole contract
      # ("the command evaluated hypothetically, nothing saved or emitted,
      # no reaction"), held to the store rather than trusted: `Replay`
      # snapshots every instance and the event count on either side of
      # each `{"dry_run": …}` step, in a SEPARATE `dry_run_traces` array
      # (same order as `history[:dry_runs]`, never merged into it — that
      # array stays the exact `{verb:, ok:, error?:}` shape the compiled
      # Rust binary's own `dry_run` answers, so `spec/rust_conformance_
      # spec.rb`'s direct comparison against it never sees a key Rust
      # doesn't have), and this is the comparison. Refused or accepted
      # makes no difference — a hypothetical that was refused had even
      # less business writing anything. Entries without the snapshots (a
      # hand-built history, an older corpus) are skipped, not failed: no
      # claim, no finding.
      module DryRuns
        def dry_runs_leave_no_trace(history)
          offenders = Array(history[:dry_run_traces]).filter_map do |entry|
            before = entry[:before]
            after  = entry[:after]
            next unless before && after

            traces = []
            traces << "events #{before[:events]} -> #{after[:events]}" unless before[:events] == after[:events]
            traces << "instances changed" unless before[:instances] == after[:instances]
            next if traces.empty?

            "dry run of #{entry[:verb]} (ok: #{entry[:ok]}) left a trace: #{traces.join(', ')}"
          end

          offenders.empty? || offenders.join("; ")
        end
      end

      # Dispatch-binding and mutation-recomputation properties: a saga/
      # policy dispatch is bound to the value its own with_spec names, and a
      # command's append/remove/multiply/clamp mutations land on the same
      # after-state an independent recomputation of the SAME rule produces.

      # Holds dispatch_binding_fidelity and mutations_match_recompute, plus
      # the independently-written re-derivations (#resolve_dispatch_binding,
      # #resolve_trigger_binding, #recompute_append/#remove/#multiply/#clamp)
      # each checks the real dispatch/mutation against.
      module DispatchAndMutations
        # Closes Handler#dispatches and — the same shape, one construct
        # over — Policy#with_spec (Dispatch#command_name/Dispatch#with_spec
        # are not claimable feature strings at all — see FEATURE_COVERAGE's
        # own comment on this entry). history[:saga_dispatches]/[:policy_dispatches]
        # (Registry#saga_dispatch_log/#policy_dispatch_log — additive,
        # Ruby-only, NEVER touching saga_log/reaction_log, the byte-for-
        # byte shape spec/rust_conformance_spec.rb holds Rust to) each
        # carry the RAW inputs a dispatch's own args were resolved from,
        # captured live at the moment the resolution actually ran — a
        # saga's own memory keeps changing across a run, so re-deriving
        # from history[:saga_instances]'s FINAL memory (the only other
        # place it would be visible) would grade the wrong moment,
        # lifecycle_guard_and_given_violations_are_refused's own false
        # positive one item earlier, in a different shape.
        #
        # #resolve_dispatch_binding/#resolve_trigger_binding are SEPARATE,
        # independently-written re-derivations of SagaInterpreter#
        # dispatch_args/PolicyInterpreter#trigger_args's own resolution —
        # never calling either method again, which would only ever agree
        # with itself. Exactly the class of bug this closes: "a wrong
        # argument binding on a fan-out dispatch that produces a perfectly
        # normal-looking log entry (`delivered: true`) and would only ever
        # surface as a downstream assertion failure, if it surfaces at
        # all" — PR #325's own defect class, one level over.
        #
        # Real targets: Settlement (mixed literal/correlation-head/event-
        # payload/memory-fallback bindings across three legs, plus a
        # compensation leg that deliberately omits `reference:`, a field
        # the forward Credit leg carries), ExternalSettlement, Onboarding
        # (no compensation leg, by design — nothing to check there beyond
        # the forward leg's own event-payload binding).
        def dispatch_binding_fidelity(history)
          saga_offenders = history.fetch(:saga_dispatches, []).filter_map do |entry|
            expected = resolve_dispatch_binding(entry)
            next if expected == entry[:args]

            "#{entry[:process_manager]}##{entry[:instance]} dispatching #{entry[:dispatch]} on #{entry[:on]} — " \
              "bound #{entry[:args].inspect}, but independently re-deriving with_spec's own resolution gives " \
              "#{expected.inspect}"
          end

          policy_offenders = history.fetch(:policy_dispatches, []).filter_map do |entry|
            expected = resolve_trigger_binding(entry)
            next if expected == entry[:args]

            "#{entry[:policy]} on #{entry[:on]} — bound #{entry[:args].inspect}, but independently re-deriving " \
              "with_spec's own resolution gives #{expected.inspect}"
          end

          offenders = saga_offenders + policy_offenders
          offenders.empty? || offenders.join("; ")
        end

        # SagaInterpreter#dispatch_args's own 4-branch resolution,
        # reproduced independently: a literal, the correlation key itself,
        # the CURRENT triggering event's own payload, or — the fallback —
        # the saga's own carried memory (seeded from the STARTING event's
        # payload, at begin_saga).
        def resolve_dispatch_binding(entry)
          entry[:with_spec].to_h do |key, value|
            resolved = if !value.is_a?(Symbol) then value
                       elsif value == entry[:correlation_head] then entry[:instance]
                       elsif entry[:event_payload].key?(value) then entry[:event_payload][value]
                       else entry[:memory][value]
                       end
            [key.to_sym, Runtime::Value.materialize(resolved)]
          end
        end

        # PolicyInterpreter#trigger_args's own 2-branch resolution — a
        # policy holds no correlation and no memory, so `payload` (the
        # triggering event's own payload, already merged with a fan-out
        # row's id when there is one) is the WHOLE source.
        def resolve_trigger_binding(entry)
          entry[:with_spec].to_h do |key, value|
            resolved = value.is_a?(Symbol) ? entry[:payload][value] : value
            [key.to_sym, Runtime::Value.materialize(resolved)]
          end
        end

        # Closes Command#mutations — the last of the five, and the
        # largest: no real corpus entity anywhere uses `append`/`remove`/
        # `multiply`/`clamp` (every real aggregate-owned mutation is
        # aggregate-scoped — Account.Credit's :ledger, LogVisit's
        # :visits); the only entity-owned use of these four ops in the
        # whole repository is spec/fixtures/entity_list_mutations, now a
        # real, bootable, Memory-default domain (no .hecksagon needed at
        # all — a domain with none boots every aggregate against Memory
        # by construction, confirmed live) rather than the raw-Kernel.
        # load-only fixture it was.
        #
        # `history[:mutation_traces]` (Replay's own bounded, additive
        # extension — see #build_mutation_trace's own comment) carries a
        # per-step before/after snapshot of the ENTITY ELEMENT an
        # entity-dispatched command's own mutations acted on, materialized
        # to plain data, plus the step's own raw args — the delta
        # `aggregation_matches_recompute` never had to ask for, because
        # count/median are pure functions of FINAL state and a mutation
        # is not (the same "captured live, not re-derived from final
        # state" lesson item 8's own saga_dispatch_log already learned).
        #
        # #recompute_append/#recompute_remove/#recompute_multiply/
        # #recompute_clamp are SEPARATE, independently-written
        # reproductions of MutationApplier#appended/#removed and
        # CommandRules::Arithmetic#multiply/#clamp — never calling either
        # again, which would only ever agree with itself. `:set`/
        # `:increment`/`:decrement` are out of scope on purpose (the four
        # "vendored, not yet upstream" ops this item exists for); a
        # command mixing them with a recomputable op still gets the
        # recomputable one checked.
        #
        # `:unrecomputable` (never compared, never a finding) covers the
        # generator's own deliberate arg-malforming (`StepBuilder#malform`)
        # landing a non-Numeric amount/non-2-element bounds where
        # multiply/clamp need one — the SAME shape `guard_check`'s own
        # AbsentArgument false positive taught: a step whose raw material
        # doesn't fit the op's own contract is inconclusive, not a claimed
        # mismatch.
        RECOMPUTABLE_MUTATION_OPS = %i[append remove multiply clamp].freeze

        def mutations_match_recompute(history)
          bluebooks = history.fetch(:bluebooks)

          offenders = history.fetch(:mutation_traces, []).flat_map do |entry|
            next [] unless entry[:after]

            command = command_for_verb(bluebooks, entry[:verb])
            next [] unless command

            aggregate = aggregate_for_verb(bluebooks, entry[:verb])
            next [] unless aggregate

            owner = owner_for_verb(bluebooks, entry[:verb]) || aggregate

            command.mutations.select { |m| RECOMPUTABLE_MUTATION_OPS.include?(m.op) }.filter_map do |mutation|
              expected = recompute_mutation(mutation, entry[:before][mutation.target], entry[:args], entry[:before],
                                            aggregate, command, owner)
              next if expected == :unrecomputable

              actual = entry[:after][mutation.target]
              next if symbolize_deep(expected) == symbolize_deep(actual)

              "#{entry[:verb]} — #{mutation.op} on #{mutation.target} — recomputing independently gives " \
                "#{expected.inspect}, but the real dispatch left #{actual.inspect}"
            end
          end

          offenders.empty? || offenders.join("; ")
        end

        # `command_for_verb`'s own root-aggregate half (Guards) —
        # re-derived independently rather than read off `entry[:domain]`/
        # `entry[:aggregate]` (present on a REAL `build_mutation_trace`
        # entry, but not on every hand-built fixture this property is
        # tested against) so this works from `entry[:verb]` alone, the
        # one field every entry always carries. BUG#5's fix needs the
        # ROOT aggregate specifically — `Value.for_attribute` resolves a
        # value-object TYPE against the root's own namespace only, the
        # same reason `EntityElement#locate_chain` threads `root_aggregate`
        # through every hop separately from each hop's own `owner`.
        def aggregate_for_verb(bluebooks, verb)
          domain_name, aggregate_name, = Naming.split_verb(verb)
          return nil unless domain_name

          bluebooks[domain_name]&.aggregate(aggregate_name)
        end

        # `mutation.target`'s own DECLARING construct — the root
        # aggregate for an aggregate-owned command (`AddSlot`'s own
        # `:slots`), or the entity a dot-shaped command belongs to
        # (`Board.AddCard`'s own `:cards`, declared on `Board`, not on
        # `Workspace`) — needed only by BUG#12's own recompute-side fix
        # (`recompute_append`, below): `entity.attribute(mutation.target)`
        # has to be asked of whichever construct actually declares it,
        # never the root aggregate unconditionally, the same distinction
        # `EntityElement#locate_chain` draws between `root_aggregate` and
        # each hop's own `owner`. Re-derived independently from
        # `entry[:verb]` alone, the same reasoning `aggregate_for_verb`'s
        # own comment gives.
        def owner_for_verb(bluebooks, verb)
          domain_name, aggregate_name, command_path = Naming.split_verb(verb)
          return nil unless command_path

          aggregate = bluebooks[domain_name]&.aggregate(aggregate_name)
          return nil unless aggregate
          return aggregate unless command_path.include?(".")

          entity_name, = command_path.split(".", 2)
          aggregate.entities.find { |candidate| candidate.hecks_name == entity_name }
        end

        def recompute_mutation(mutation, current, args, before_scope, aggregate, command, owner = aggregate)
          case mutation.op
          when :append
            recompute_append(current, mutation.source, before_scope, args, aggregate, command, owner, mutation.target)
          when :remove   then recompute_remove(current, mutation.source, args)
          when :multiply then recompute_multiply(current, resolve_mutation_source(mutation.source, args))
          when :clamp    then recompute_clamp(current, mutation.source)
          end
        end

        # `EntityElement#appended_to_element`'s own field-mapping half,
        # reproduced: the field map resolved the SAME two-tier way
        # (`MutationApplier#resolve_append_source` — a caller-supplied
        # arg, or the entity's own current field), then appended. (An
        # entity-dispatched command's own mutations DO reach here —
        # `#build_mutation_trace`'s own comment describing them as never
        # reaching "the entity_element branch" means `MutationApplier#
        # appended`'s own AGGREGATE-level entity_element fallback
        # specifically, which really is unreached from here; entity-owned
        # append dispatches go through `EntityElement#appended_to_element`
        # instead, and DO reach this method.)
        #
        # BUG#5 — an entity-owned `:append` whose target field is itself
        # value-object-typed (`Board.AddCard`'s own `sets :cards, append:
        # { sequence: :sequence }`, `CardSequence`-typed). A caller-
        # supplied arg reaches the REAL applier (`EntityElement#
        # appended_to_element`) already coerced: `Interpreting#
        # coerce_declared_arguments` runs `Value.for_attribute` over
        # EVERY arg the acting command itself declares, BEFORE dispatch
        # ever reaches a mutation applier at all — independent of, and
        # earlier than, anything `appended_to_element`'s own value_object
        # check does. `before_scope[source]` (the entity's OWN current
        # field) needs no such re-coercion here: it's already the
        # MATERIALIZED shape `build_mutation_trace` snapshotted it in
        # (`Value.materialize`, same as `entry[:after]`), not a raw value
        # sitting behind a live `Value`.
        #
        # BUG#12 — `owner`/`target` (new here) let this ALSO reproduce
        # `EntityElement#fill_declared_defaults`'s own entity-nested-in-
        # entity fallback (`appended_to_element`'s `else` branch, when
        # the appended element is itself an entity — `Card`, nested
        # inside `Board` — not a value object): `owner.attribute(target)
        # &.type` names the appended element's own type; when that names
        # an entity of `aggregate` rather than a value object, every one
        # of ITS OWN declared attributes `fields` doesn't already hold
        # gets `Instance.default_for`'s own default — reused, not
        # reimplemented, for the identical "never agree with itself"
        # reason BUG#5's own coercion re-derivation above already gives:
        # `Instance.default_for` is pre-existing, independently-tested
        # machinery (an ordinary aggregate's own creation already runs
        # through it via `Instance.defaults`), not the NEW glue
        # (`fill_declared_defaults` itself) this property exists to
        # catch a drift in.
        def recompute_append(current, source_map, before_scope, args, aggregate, command, owner = aggregate, target = nil)
          fields = source_map.transform_values do |source|
            resolve_mutation_append_field(source, before_scope, args, aggregate, command)
          end
          fill_recompute_declared_defaults(aggregate, owner, target, fields)
          Array(current) + [symbolize_deep(fields)]
        end

        # BUG#12's own recompute-side half — see `#recompute_append`'s
        # own comment above for why this exists and why it reuses
        # `Instance.default_for` rather than calling `EntityElement#
        # fill_declared_defaults` again. A no-op whenever `target` names
        # no attribute at all (every RECOMPUTABLE_MUTATION_OPS caller but
        # `:append` passes no `target`) or `target`'s own declared type
        # isn't an entity nested directly under `owner` (a value object,
        # or nothing declared at all — `owner.attribute` answering `nil`
        # for a target the DSL itself would already have refused at
        # build time). `owner.entities`, NOT `aggregate.entities` — a
        # piece nested inside a piece is a child of the OWNING entity
        # (`Card` is `Board.entities`, never `Workspace.entities`), the
        # same distinction `EntityElement#appended_to_element`'s own fix
        # draws.
        def fill_recompute_declared_defaults(aggregate, owner, target, fields)
          return fields unless target

          element_type = owner&.attribute(target)&.type
          entity = element_type && owner.entities.find { |piece| piece.hecks_name == element_type.to_s }
          return fields unless entity

          entity.attributes.each do |attribute|
            next if fields.key?(attribute.name)

            fields[attribute.name] = attribute.list? ? [] : Runtime::Instance.default_for(aggregate, attribute)
          end
          fields
        end

        def resolve_mutation_append_field(source, before_scope, args, aggregate, command)
          return source unless source.is_a?(Symbol)
          return before_scope[source] unless args.key?(source)

          coerce_recompute_append_arg(aggregate, command, source, args[source])
        end

        # `Interpreting#coerce_declared_arguments`'s own coercion,
        # reproduced independently (never calling it again, the same
        # "never agree with itself" rule this whole module's header
        # comment gives) — a raw arg is coerced ONLY when its own name
        # (`source`) is one of the ACTING COMMAND's own declared
        # attributes, exactly the condition that method checks before a
        # real dispatch ever coerces it either. `command.attribute(source)`
        # answering `nil` (a source that names no declared attribute —
        # never possible for `coerce_declared_arguments` to have touched
        # it in the real dispatch either) leaves `raw` exactly as it
        # arrived, the same as every bare-scalar append this already
        # handled correctly before BUG#5's fix.
        #
        # `Value.materialize`d immediately after coercing — matching the
        # plain-data shape `entry[:before]`/`entry[:after]` already carry
        # throughout this whole property, so the eventual `symbolize_deep`
        # comparison is always materialized-against-materialized, never a
        # live `Value` against a Hash.
        def coerce_recompute_append_arg(aggregate, command, source, raw)
          attribute = command.attribute(source)
          return raw unless attribute

          Runtime::Value.materialize(Runtime::Value.for_attribute(aggregate, attribute, raw, argument: true))
        end

        # `MutationApplier#removed`'s own value-equality match, reproduced.
        def recompute_remove(current, source, args)
          target = symbolize_deep(resolve_mutation_source(source, args))
          Array(current).reject { |element| symbolize_deep(element) == target }
        end

        # `CommandRules::Arithmetic#multiply`'s own two branches,
        # reproduced on plain materialized data instead of a real Value:
        # a single-numeric-field Hash (the VO-typed case — ListCount, one
        # Integer field) scales that field ; a bare Numeric scales itself.
        # `current ||= 0` — the SAME phantom-field fallback #multiply
        # itself already gives (unaffected by this session's #clamp fix,
        # since #multiply never needed one).
        def recompute_multiply(current, amount)
          return :unrecomputable unless amount.is_a?(Numeric)

          current ||= 0
          if current.is_a?(Hash)
            field = current.keys.find { |f| current[f].is_a?(Numeric) }
            return :unrecomputable unless field

            current.merge(field => current[field] * amount)
          elsif current.is_a?(Numeric)
            current * amount
          else
            :unrecomputable
          end
        end

        # `CommandRules::Arithmetic#clamp`'s own two branches, reproduced
        # the same way #recompute_multiply is — including THIS SESSION'S
        # OWN `current ||= 0` fix (command_rules/arithmetic.rb), the one
        # arithmetic op that didn't have it until now. `mutation.source`
        # is always a literal `[min, max]`, never an argument reference
        # (MutationApplier's own comment on why `resolve_source` is
        # skipped for clamp) — so nothing here reads `args` for it at all.
        def recompute_clamp(current, bounds)
          return :unrecomputable unless bounds.is_a?(Array) && bounds.size == 2

          min, max = bounds
          current ||= 0
          if current.is_a?(Hash)
            field = current.keys.find { |f| current[f].is_a?(Numeric) }
            return :unrecomputable unless field

            current.merge(field => current[field].clamp(min, max))
          elsif current.is_a?(Numeric)
            current.clamp(min, max)
          else
            :unrecomputable
          end
        end

        # `CommandRules::Arithmetic#resolve_source`, reproduced: a
        # mutation's source is either the NAME OF AN ARGUMENT or a
        # LITERAL, told apart by type.
        def resolve_mutation_source(source, args)
          source.is_a?(Symbol) ? args[source] : source
        end

        # A generated step's own `args` arrive with STRING keys on every
        # nested Hash (the wire/JSON shape `spec/corpus/*.json` already
        # uses) while `history[:mutation_traces]`' own materialized
        # before/after state carries SYMBOL keys throughout (Runtime::
        # Value.materialize's own convention) — two hashes holding the
        # identical fact compare UNEQUAL by Ruby's own `Hash#==` unless
        # both sides are normalized the same way first. Recursive, since
        # an appended/removed element can itself nest a value object
        # (RemoveTag's own `Tag` argument, `{"key"=>..., "value"=>...}`).
        def symbolize_deep(value)
          case value
          when Hash  then value.to_h { |key, val| [key.to_sym, symbolize_deep(val)] }
          when Array then value.map { |val| symbolize_deep(val) }
          else value
          end
        end
      end
    end
  end
end
