require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "command_interpreter/mutation_applier"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "dependency_planning"
require_relative "../ports/persistence/execution"
require_relative "instance"
require_relative "refusal_wording"
require_relative "entity_element"
require_relative "rebuild_sweep"

module Hecks
  module Runtime
    # The dispatch pipeline for a command on an aggregate head. The payload
    # gate lives in command_interpreter/argument_gate.rb, the mutation walk
    # in command_interpreter/mutation_applier.rb; what stays here is the
    # order of the steps and how a record is addressed.
    class CommandInterpreter
      include Interpreting
      include ArgumentGate
      include MutationApplier

      attr_reader :registry

      # **The declared order** — Vocabulary::AggregateDispatchOrder
      # (language/bluebook/vocabulary.bluebook), read off the generated table
      # (lib/hecks/vocabulary.rb) rather than typed here. spec/vocabulary_
      # conformance_spec.rb holds every step to a real `step_<name>` handler,
      # both directions.
      DISPATCH_ORDER = Hecks::Vocabulary.symbols("AggregateDispatchOrder")

      # **A last-resort safety valve**, not the normal outcome path — see
      # `Runtime::StaleWrite`'s own comment. Two concurrent writers
      # against one aggregate resolve through exactly one retry in the
      # ordinary case (the loser's retried hydrate reads the winner's now-
      # committed state and its own `given` refuses for real, raising
      # `GivenNotMet`, not `StaleWrite`) — this cap exists for pathological
      # contention (many concurrent writers on one hot aggregate), not the
      # two-writer case.
      MAX_STALE_WRITE_RETRIES = 5

      # Every cross-step local, held in one place now that the sequence is
      # data-driven rather than `call`'s own literal sequence of steps —
      # `result` and `transition`/`old_state` default to nil until the step
      # that sets them runs, the same as unset locals would.
      Context = Struct.new(:domain, :aggregate, :command, :args, :repository, :instance, :transition, :old_state,
                           :result, :correlation, :route, :plan, :strategy, :persistence_outcome, :pending_delegation,
                           :dry_run, :correction_bindings, :outbox_rows, :invocation)

      # @param registry [Runtime::Registry] the booted registry this interpreter dispatches
      #   against
      # @param rules [Runtime::CommandRules] the shared command-rule checks (givens, ensures,
      #   invariants, references, emission) this interpreter's steps call
      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # `dry_run:` — Dispatcher#dry_run?'s own entry point. Every step up
      # through enforce_ensures/enforce_invariants runs exactly as a real
      # dispatch would (givens checked, mutations applied to `ctx.instance`
      # in memory); `step_save`/`step_emit` are the only two that read this
      # flag, each skipping its own real work — see their own comments.
      # Retries the whole method body on `StaleWrite` — a fresh `ctx`, a
      # fresh `step_hydrate` re-reading current state, so `enforce_givens`
      # re-evaluates against reality rather than the snapshot that just
      # went stale. See `MAX_STALE_WRITE_RETRIES`/`Runtime::StaleWrite`
      # for why exhaustion is a pathological-contention signal, not the
      # expected shape of a two-writer race.
      #
      # `invocation` — the `Runtime::Invocation` `Dispatcher` built for this
      # call. `ctx.args` is `invocation.to_args` (the same Hash routing
      # always handed this method), `ctx.route` its `target`.
      #
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate the command acts on
      # @param command [Bluebook::Command] the command to dispatch
      # @param invocation [Runtime::Invocation] the invocation `Dispatcher` built for this call
      # @param correlation [Hash{Symbol => Object}, nil] correlation head => value, stamped on
      #   every emitted event when a saga leg causes this dispatch
      # @param dry_run [Boolean] true to run every step through `enforce_invariants` without
      #   saving or emitting
      # @return [Array(Runtime::Instance, Array<Runtime::Event>, Hecks::Runtime::
      #   DependencyPlanning::Plan, Ports::Persistence::Outcome, Array<Outbox::Row>, nil)]
      #   the settled record, the events emitted (`[]` on a dry run), the dependency plan, the
      #   persistence outcome, and the enqueued outbox rows (nil without an outbox)
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the domain refuses
      #   the call
      # @raise [Runtime::StaleWrite] if concurrent writers beat this one through every retry
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def call(domain, aggregate, command, invocation, correlation = nil, dry_run: false)
        args    = invocation.to_args
        route   = invocation.target
        attempt = 0
        begin
          ctx = Context.new(domain, aggregate, command, args)
          ctx.invocation = invocation
          ctx.correlation = correlation
          ctx.route = route
          ctx.dry_run = dry_run
          ctx.plan = DependencyPlanning::Analyzer.call(aggregate: aggregate, command: command)
          # **Resolved here, once, before hydration** — `Registry#repository`
          # memoizes, so this and `step_hydrate`'s own read of `ctx.repository`
          # (no second fetch there any more) always name the same instance;
          # the isolation decision below (lock vs. CAS+retry) needs the
          # repository's capabilities before a single step runs.
          ctx.repository = @registry.repository(domain, aggregate)
          lock_id = Identity.best_effort(aggregate, args, route, reference_key: reference_key(command))
          run_dispatch_order_with_isolation(DISPATCH_ORDER, ctx, lock_key_id: lock_id)
          [ctx.instance, ctx.result, ctx.plan, ctx.persistence_outcome, ctx.outbox_rows]
        rescue StaleWrite
          attempt += 1
          retry if attempt < MAX_STALE_WRITE_RETRIES
          raise
        end
      end

      private

      # **A no-op, and untraced** — Vocabulary::AggregateDispatchOrder's
      # decode_arguments. Routing (`Runtime::Routing`) has already handed
      # `call` a decoded argument hash by the time any step runs, so there is
      # nothing left to decode here yet; like a conditional step that does
      # not fire, it records nothing in `trace`. Declared so the Rust
      # kernel's generated step enum carries the step its generated decoder
      # will move into (roadmap D2), and so a typed Invocation (I2) has a
      # step to be consumed at.
      def step_decode_arguments(_ctx); end

      def step_refuse_unknown_arguments(ctx)
        step(:refuse_unknown_arguments) { refuse_unknown_arguments(ctx.domain, ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_refuse_absent_arguments(ctx)
        step(:refuse_absent_arguments) { refuse_absent_arguments(ctx.command, ctx.args) }
      end

      def step_normalize_args(ctx)
        ctx.args = step(:normalize_args) { normalize_args(ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_refuse_role_mismatch(ctx)
        step(:refuse_role_mismatch) { @rules.refuse_role_mismatch(ctx.command, ctx.domain) }
      end

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.command, ctx.args) }
      end

      def step_hydrate(ctx)
        # `ctx.repository` is resolved once, in `#call`, before the
        # isolation decision (lock vs. CAS+retry) — not here any more.
        ctx.strategy = ctx.plan.strategy_for(capabilities: ctx.repository.capabilities)
        ctx.instance = step(:hydrate) do
          if ctx.plan.complete_state? && ctx.plan.state_independent?
            hydrate_complete_state(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route, ctx.strategy)
          elsif ctx.plan.complete_state?
            hydrate_prior_or_initial(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route)
          elsif legacy_implicit_creation?(ctx)
            hydrate_legacy_creation(ctx.repository, ctx.aggregate, ctx.command, ctx.args)
          else
            hydrate_existing(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route)
          end
        end
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) do
          # Structural, before the declared givens — the same ordering
          # NotFound/AlreadyExists already get at hydration: "does the
          # fact this command's corrects names even exist" is not a
          # domain rule an author wrote, it is a precondition for the
          # domain rules to mean anything at all. Also locates the
          # correction target itself, if `as:` named one — carried on
          # `ctx` so `step_enforce_ensures` (the settled-record half)
          # can bind the same name too, not just this pre-mutation half.
          ctx.correction_bindings = @rules.enforce_correction_target(ctx.instance, ctx.aggregate, ctx.command, domain: ctx.domain)
          @rules.enforce_givens(ctx.instance, ctx.command, ctx.args, domain: ctx.domain,
                                declaring: ctx.aggregate, parent: ctx.instance, correction: ctx.correction_bindings)
        end
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.aggregate, ctx.command, ctx.instance) }
      end

      def step_assign_creation_attributes(ctx)
        return unless legacy_implicit_creation?(ctx)

        step(:assign_creation_attributes) { assign_creation_attributes(ctx.instance, ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_apply_mutations(ctx)
        # The state as the givens saw it — what `old` names inside an
        # ensures. A shallow dup suffices: mutations replace fields (set,
        # arithmetic via Value#with, append builds a new array), never
        # edit a held value in place.
        ctx.old_state = ctx.instance.state.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) do
          # One update set over the pre-dispatch state (C4.2, docs/
          # semantics/bluebook-semantics.md): every effect's sources read
          # `pre` — the state as it was before this command — and its
          # target is written to the candidate; declaration order carries
          # no meaning, and build refuses a field written twice.
          pre = ctx.instance.state.dup
          ctx.command.mutations.each do |mutation|
            apply(ctx.instance, ctx.aggregate, mutation, ctx.args, pre)
          end
        end
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.instance[ctx.aggregate.lifecycle.field] = ctx.transition.target }
      end

      # The synchronous cousin of a policy's own `trigger` — see
      # `CommandBuilder#delegates_to`'s own comment for the full reasoning.
      # Runs after this command's own mutations/lifecycle (so a delegating
      # command could in principle still guard with its own `given`s first,
      # though the real use in `domain/chess` declares none) and before
      # `enforce_ensures`/`enforce_invariants`/`save`, so a refusal here
      # raises a real, unrescued exception and nothing from either side —
      # this command's own state, the target element's — has been saved
      # yet. `ctx.instance` is the same in-memory record `step_hydrate`
      # loaded and `step_save` will persist; `EntityElement.locate_chain`
      # mutates it in place exactly the way `EntityInterpreter`'s own
      # `step_locate_element`/`step_apply_mutations` mutate their own
      # freshly-loaded copy — the only difference is which already-in-
      # memory record gets handed in.
      #
      # Reimplements the entity command pipeline's own order (givens,
      # transition, mutations, ensures, emit) inline, deliberately — see
      # the comment above on why this must run strictly between this
      # command's own mutations and its ensures/invariants/save. Splitting
      # it would scatter that exact ordering across method boundaries and
      # force threading element/view/transition/old_element/settled
      # through as parameters — the `with:` bug documented just below is
      # exactly the kind of ordering/plumbing mistake that shape invites.
      # rubocop:disable-next Metrics/AbcSize
      def step_delegate_to_entity(ctx)
        delegation = ctx.command.mutations.find { |mutation| mutation.op == :delegate }
        return unless delegation

        step(:delegate_to_entity) do
          entity_name, _dot, command_name = delegation.target.to_s.rpartition(".")
          entity = ctx.aggregate.entities.find { |e| e.hecks_name == entity_name } ||
                   raise(WiringError, "#{ctx.command.hecks_name} delegates_to #{entity_name}." \
                                      "#{command_name}, but #{ctx.aggregate.hecks_name} has no " \
                                      "entity named #{entity_name.inspect}")
          target_command = entity.command(command_name) ||
                           raise(WiringError, "#{ctx.command.hecks_name} delegates_to " \
                                              "#{entity_name}.#{command_name}, which " \
                                              "#{entity_name} declares no such command")

          # `with:` remaps, it does not enumerate — starting from a copy
          # of this command's own already-resolved args (`ctx.args`) and
          # overlaying the explicit mapping on top means ambient context
          # the caller never had to think about (the aggregate's own
          # identity, addressed the ordinary way to reach `MoveKnight` at
          # all) flows through to the target untouched, the same as it
          # always would for a caller dispatching the entity command
          # directly. Confirmed necessary, not a defensive guess: a real
          # downstream domain's own AdvancePly-on-Moved policy silently
          # failed to re-locate its own aggregate (`reaction_log`: "no
          # Game with label.value ..."), because the emitted event's
          # payload — built from `target_args` alone — never carried
          # `label` at all when `with:` named only `id`/`to`.
          target_args = ctx.args.merge(
            delegation.source.to_h { |target_key, source_key| [target_key.to_sym, ctx.args[source_key]] }
          )

          element = EntityElement.locate_chain(ctx.aggregate, [entity], ctx.instance, target_args, command_name)
          view = Instance.new(aggregate: entity, id: EntityElement.element_identity(entity, element).to_s, state: element)

          @rules.enforce_givens(view, target_command, target_args, domain: ctx.domain, declaring: entity, parent: ctx.instance)
          transition = @rules.admissible_transition(entity, target_command, view)

          old_element = target_command.ensures.empty? ? nil : element.dup
          pre = element.dup # C4.2 — the update set reads the element as it was
          target_command.mutations.each do |mutation|
            EntityElement.apply_to_element(@rules, ctx.aggregate, entity, element, mutation, target_args, pre)
          end
          element[entity.lifecycle.field] = transition.target if transition

          settled = Instance.new(aggregate: entity, id: view.id, state: element)
          @rules.enforce_ensures(settled, target_command, target_args, old: old_element, domain: ctx.domain, parent: ctx.instance)

          # Not emitted here — C7.2 (docs/semantics/bluebook-semantics.md):
          # a refused command records nothing, and the parent's own
          # `ensures`/`enforce_invariants`/`save` steps still run after
          # this one. The target's emission is parked and performed by
          # `step_emit`, after the parent committed — where every other
          # command's events are emitted too, rather than putting the
          # entity leg's events on the event log and in the adapter before
          # the parent has a chance to refuse.
          ctx.pending_delegation = [target_command, target_args]
        end
      end

      def step_enforce_ensures(ctx)
        step(:enforce_ensures) do
          @rules.enforce_ensures(ctx.instance, ctx.command, ctx.args, old: ctx.old_state,
                                 domain: ctx.domain, parent: ctx.instance, correction: ctx.correction_bindings || {})
        end
      end

      def step_enforce_invariants(ctx)
        step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
      end

      # `dry_run:` skips the write half of this step — see Dispatcher#
      # dry_run?'s own comment — but not `resolve_state_references`.
      # BUG#127: that check is validation, not persistence — it asks
      # whether the settled in-memory state names a reference target that
      # actually exists, the same question a real dispatch answers before
      # it ever writes anything. Skipping it under `dry_run:` made
      # `dry_run?` disagree with what a real dispatch immediately after it
      # would do: it answered `true` ("would succeed") for a command whose
      # real dispatch refuses with NotFound. Only the persist/raise-on-
      # conflict tail is genuinely persistence-only and stays behind the
      # early return.
      #
      # BUG#132 — a second validation-not-persistence check hid in that
      # same persist/raise-on-conflict tail: `persist_instance`'s own
      # ATOMIC_PUT branch (below) is where `hydrate_complete_state`'s
      # comment says a `creates?` command's duplicate check is
      # deliberately deferred to, for a strategy this fast — a read
      # (`repository.find`) any earlier, before the real write, would be
      # exactly the extra read `insert_only:` exists to avoid paying on
      # every real dispatch. But that means the check never ran at all under
      # `dry_run:` — not eagerly (hydration skips it for this exact
      # strategy, on purpose) and not deferred (this whole branch returns
      # first). `Roster::Roster.Open` against an already-open name is
      # this shape: `dry_run?` answered `true` for a real dispatch
      # immediately after it that refuses `AlreadyExists`. Under
      # `dry_run:` there is no write to race, so paying for that one read
      # is safe here — and only here.
      def step_save(ctx)
        step(:save) { @rules.resolve_state_references(ctx.domain, ctx.aggregate, ctx.instance.state) }

        if ctx.dry_run
          step(:save) { check_dry_run_creates_duplicate(ctx) }
          return
        end

        step(:save) do
          seed_projected_fields(ctx)
          ctx.persistence_outcome = persist_instance(ctx)
          raise_for_persistence_outcome!(ctx)
        end
      end

      # See `step_save`'s own BUG#132 comment: the only path, real or dry,
      # able to catch a `creates?` command reusing an already-occupied
      # identity when `strategy` is `ATOMIC_PUT` — `hydrate_complete_
      # state` deliberately skips this exact case (its own comment), and
      # a dry run never reaches `persist_instance`'s matching branch.
      def check_dry_run_creates_duplicate(ctx)
        return unless ctx.strategy == DependencyPlanning::ATOMIC_PUT && ctx.command.creates?
        return unless ctx.repository.find(ctx.instance.id)

        raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                        command: ctx.command.hecks_name, aggregate: ctx.aggregate.hecks_name,
                                                        identity: identity_reading(ctx.aggregate),
                                                        offered: Rendering.describe(ctx.instance.id)))
      end

      def persist_instance(ctx)
        if ctx.strategy == DependencyPlanning::ATOMIC_PUT
          # **A second creation is not fresh** — see
          # hydrate_complete_state's own comment; the
          # same refusal, on the same terms, for the
          # complete-state path. `insert_only:` asks the
          # adapter to decide and refuse atomically
          # (never writing a `creates?` command over an
          # identity that already names a record) rather
          # than this interpreter reading the record
          # first to check — a `repository.find` before
          # every atomic_put would be exactly the read
          # this strategy exists to skip.
          ctx.repository.atomic_put(ctx.instance, insert_only: ctx.command.creates?)
        else
          # `expected_version:` is `ctx.instance.version` — nil for a
          # brand-new record (never read from storage) or when the
          # repository isn't CAS-capable, either of which falls straight
          # through to a plain, unconditional save inside `AppendOnly#save`.
          ctx.repository.save(ctx.instance, expected_version: ctx.instance.version)
        end
      end

      def raise_for_persistence_outcome!(ctx)
        if ctx.persistence_outcome.status == :conflicted
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: ctx.command.hecks_name, aggregate: ctx.aggregate.hecks_name,
                                                          identity: identity_reading(ctx.aggregate),
                                                          offered: Rendering.describe(ctx.instance.id)))
        elsif ctx.persistence_outcome.status == :stale
          # Not a `RefusalWording.render` call — this is not a declared
          # vocabulary refusal, just a plain, informative message. See
          # `Runtime::StaleWrite`'s own comment: caught by `#call`'s
          # retry loop, re-raised only once retries are exhausted.
          raise(StaleWrite,
                "#{ctx.command.hecks_name} on #{ctx.aggregate.hecks_name} " \
                "(#{identity_reading(ctx.aggregate)}: #{Rendering.describe(ctx.instance.id)}) lost a race — " \
                "another write committed against this record after it was read")
        end
      end

      # The one-time, synchronous half of `projects` (S12, ADR 0025) —
      # `RebuildSweep` (`runtime/rebuild_sweep.rb`) is deliberately the
      # only thing that keeps a projected field current against a
      # target that changes after this record was written — no reactive
      # `Policy#for_each` keeping it live in real time, that stays
      # deferred, same as that file's own header explains. But without
      # some synchronous population, a projected field never gets an
      # initial value at all until an operator remembers to run a
      # sweep by hand — every acting command reading it (`given
      # ("customer is active") { customer_status == "active" }`, say)
      # would refuse a freshly created, genuinely active record for no
      # real reason, which is not the eventual-consistency tradeoff the
      # ADR accepts, just a bug. So: every time a record with `projects`
      # fields is about to save — creating or acting, either can be the
      # first time a referenced record resolves — read each one once,
      # here, using the exact same `RebuildSweep.remote_value` a sweep
      # itself would compute. This is still eventually consistent in
      # the sense the ADR means: a change on the target side after this
      # save still needs a sweep to reach here. It is only ever
      # synchronous with this record's own write, never a live read
      # triggered by a `given`/`ensures`/`invariant` mid-dispatch — the
      # boundary rule those enforce holds exactly as before.
      def seed_projected_fields(ctx)
        return if ctx.aggregate.projected_fields.empty?

        ctx.aggregate.projected_fields.each do |field|
          value = RebuildSweep.remote_value(@registry, ctx.domain, ctx.aggregate, ctx.instance.state, field)
          next if value.nil?

          ctx.instance.state[field.name] = value
        end
      end

      # A delegating command emits nothing of its own (`CommandBuilder#build`'s
      # own guard refuses declaring `emits` alongside `delegates_to`) — its
      # result is the target entity command's own `emits`, parked by
      # `step_delegate_to_entity` and emitted here, after save (C7.2), not
      # a second, empty call into `@rules.emit` for a command with no
      # announced events at all.
      #
      # `dry_run:` skips this too, same reasoning as `step_save` — nothing
      # was committed, so `ctx.result` stays nil and `Dispatcher#dry_run?`
      # never reads it (its own return value is just whether this raised).
      def step_emit(ctx)
        return if ctx.dry_run

        ctx.result = step(:emit) do
          # `ctx.pending_delegation` is only ever set by
          # `step_delegate_to_entity`, and only when this command carries a
          # `:delegate` mutation.
          if ctx.pending_delegation
            target_command, target_args = ctx.pending_delegation
            # The same dispatch, so the same correlation — passed through
            # explicitly here so a saga-driven door's events keep their stamp.
            next @rules.emit(target_command, ctx.domain, ctx.aggregate, ctx.instance, target_args, ctx.repository,
                             ctx.correlation)
          end

          @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository, ctx.correlation)
        end
      end

      def hydrate_existing(repository, aggregate, command, args, route = nil)
        if route
          found = repository.find(route.aggregate) ||
                  raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                             aggregate: aggregate.hecks_name,
                                                             identity:  identity_reading(aggregate),
                                                             offered:   Rendering.describe(route.aggregate)))
          return found.dup
        end

        id = identity_of(aggregate, args) ||
             identity_from(aggregate, args, :id) ||
             identity_from(aggregate, args, reference_key(command)) ||
             raise(NotFound, RefusalWording.render_site("NotFound", "acting_no_identity",
                                                        command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                        identity: identity_reading(aggregate)))
        found = repository.find(id) ||
                raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                           aggregate: aggregate.hecks_name,
                                                           identity:  identity_reading(aggregate),
                                                           offered:   Rendering.describe(id)))
        found.dup
      end

      # Wave 8 (equivalence-gap plan, item 1.6) — not done, and this
      # comment now says precisely how far it got, corrected from an
      # earlier version of itself that briefly (same PR, never released)
      # claimed the inventory was empty and deleted this method outright.
      # A full corpus audit (`DependencyPlanning::Analyzer.call` against
      # every `creates?`-true command in all 5 example domains — banking,
      # pizzas, chess, compliance, roster) found and fixed 4 real
      # authoring bugs (`Statement.Generate`, `CreatePizza`, `Chess::
      # Game.Start`, `Roster.Open` — each declared an attribute and
      # never `sets` it, so the field silently stayed nil on every
      # created record regardless of what a caller sent), plus a real
      # `DependencyPlanning::Analyzer` bug for entity-owned commands
      # (`root_aggregate:`, that class's own header) that surfaced one
      # more live corpus bug of its own (`payment_cards.bluebook`'s own
      # `Withdrawal.Dispute`, which never actually checked whether the
      # card was retired) — all real, all kept.
      #
      # Deleting this method on that basis turned out to be wrong,
      # caught by running the full suite rather than trusting the
      # audit's own scope: the 5 example domains are nowhere near the
      # whole inventory of `creates?`-true commands this fallback
      # actually carries. Dozens of separate, purpose-built spec
      # fixtures across the suite (`spec/fixtures/*.bluebook`, and
      # inline `Hecks.bluebook` blocks declared directly inside
      # individual spec files — governance, mutation ops, ports,
      # routing, tenant isolation, sagas, and more) declare their own
      # small `creates?`-true commands the same incomplete way, and
      # rely on this exact fallback to create anything at all. Deleting
      # it produced 218 failures across specs with nothing to do with
      # Wave 8's own subject — confirmed, not guessed, by actually
      # running `bundle exec rspec` after the deletion, not merely by
      # extrapolating from the one audited inventory. `spec/fixtures/
      # till.bluebook`'s own `Till.OpenTill` (missing `sets :number`,
      # the identical bug shape as the 4 fixed above) was fixed
      # alongside the four real corpus ones as one instance of this — but
      # it was one of many, not the last one, and finding the rest is
      # real, separate, much larger follow-up work this pass does not
      # attempt: a suite-wide audit of every declared bluebook fixture,
      # not just the 5 example domains the plan's own text named.
      #
      # Transitional compatibility for live source that has not yet
      # acquired explicit effects, same as it always was — deliberately
      # isolated from the normal routing and planning path so
      # `reference_to` no longer chooses how a migrated command hydrates
      # or persists. A real, future Wave 8 removes this once that wider
      # inventory is empty, not before.
      #
      # `ctx.plan.complete_state?` already claimed every command whose
      # plan is fully resolved in the two branches above `step_hydrate`
      # tries first, so reaching this check already means the plan is
      # incomplete — an un-migrated command still routes here on
      # `creates?` alone, the same as the old `hydrate` did, regardless
      # of whether it happens to have any mutations (`write_set`).
      # Requiring an empty write_set here refused every un-migrated
      # creating command that sets even one field.
      def legacy_implicit_creation?(ctx)
        ctx.route.nil? && ctx.command.creates?
      end

      def hydrate_legacy_creation(repository, aggregate, command, args)
        id = identity_of(aggregate, args) ||
             raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                        command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                        identity: identity_reading(aggregate)))
        if repository.find(id)
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                          identity: identity_reading(aggregate),
                                                          offered: Rendering.describe(id)))
        end

        Instance.new(aggregate: aggregate, id: id, args: args)
      end

      def hydrate_complete_state(repository, aggregate, command, args, route, strategy)
        derived = identity_of(aggregate, args)
        if route && derived && route.aggregate.to_s != derived.to_s
          raise TypeMismatch,
                "#{command.hecks_name} routes to #{route.aggregate.inspect}, but its identity facts name #{derived.inspect}"
        end

        id = route&.aggregate || derived ||
             raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                        command:   command.hecks_name,
                                                        aggregate: aggregate.hecks_name,
                                                        identity:  identity_reading(aggregate)))

        # **A second creation is not fresh** — `creates?` on an identity
        # a record already exists under refuses (`AlreadyExists`) rather
        # than silently overwriting it, the same refusal `hydrate_prior_
        # or_initial`'s own body gives for its own complete-but-state-
        # dependent case, below. Only when `strategy` will not be ATOMIC_PUT:
        # an atomic-put-capable adapter enforces this itself, atomically,
        # via `insert_only:` in step_save (no read here, no race with the
        # write) — but `strategy_for` already fell back to a plain `save`
        # for an adapter with no atomic_put capability at all (Heki, today),
        # and a plain `save` never refuses an overwrite on its own. Skipping
        # this check for that case silently dropped the refusal instead of
        # deferring it — the very "no such call — no such check" gap Wave
        # 8 exists to close everywhere else.
        if command.creates? && strategy != DependencyPlanning::ATOMIC_PUT && repository.find(id)
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                          identity: identity_reading(aggregate),
                                                          offered: Rendering.describe(id)))
        end

        Instance.new(aggregate: aggregate, id: id, args: args)
      end

      # A complete command may still depend on prior state: lifecycle guards
      # are the common case. Read once so an existing record is checked against
      # its real state; when no record exists, the aggregate's declared defaults
      # are the prior state. Completeness, not a reference marker, proves that
      # initializing that missing record is safe.
      def hydrate_prior_or_initial(repository, aggregate, command, args, route)
        derived = identity_of(aggregate, args)
        if route && derived && route.aggregate.to_s != derived.to_s
          raise TypeMismatch,
                "#{command.hecks_name} routes to #{route.aggregate.inspect}, but its identity facts name #{derived.inspect}"
        end

        id = route&.aggregate || derived ||
             raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                        command:   command.hecks_name,
                                                        aggregate: aggregate.hecks_name,
                                                        identity:  identity_reading(aggregate)))
        found = repository.find(id)

        # **A second creation is not fresh** — see hydrate_complete_
        # state's own comment; the same refusal, on the same terms, for
        # a complete-but-state-dependent command (one with a `given`
        # reading its own prior state, which is what routes here instead
        # of hydrate_complete_state). Gated on `command.creates?`: a
        # non-creating command's own complete payload legitimately means
        # "act on whatever this identity already holds" (`found` is the
        # prior state this branch exists to supply), so only a genuine
        # creation reusing an already-occupied identity is a duplicate.
        # `SafeDepositBox.Rent` is exactly this shape — `given("box is
        # vacant")` makes it state-dependent, so without this guard a
        # second Rent would silently hydrate the existing box as "prior
        # state" and refuse for the wrong reason (not vacant) instead of
        # the right one (already exists).
        if found && command.creates?
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                          identity: identity_reading(aggregate),
                                                          offered: Rendering.describe(id)))
        end

        found ? found.dup : Instance.new(aggregate: aggregate, id: id, args: args)
      end

      # **The join, the dig, the reading** — all shared with `EntityInterpreter`
      # now, in `Runtime::Identity`, rather than kept as two copies that could
      # only ever drift. See that module for the reasoning ; these three stay
      # here, at the old names, purely so nothing below has to change.
      def identity_of(aggregate, args)   = Identity.of(aggregate, args)
      def identity_from(aggregate, args, key) = Identity.from(aggregate, args, key)
      def identity_reading(construct)    = Identity.reading(construct)
    end
  end
end
