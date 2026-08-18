require_relative "interpreting"
require_relative "../naming"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "value"
require_relative "refusal_wording"
require_relative "entity_element"

module Hecksagain
  module Runtime
    class EntityInterpreter
      include Interpreting

      attr_reader :registry

      # THE DECLARED ORDER, HAND-TYPED — mirrors Vocabulary::EntityDispatchOrder
      # (language/bluebook/vocabulary.bluebook:217-232), held equal to it by
      # spec/vocabulary_conformance_spec.rb the same way CommandInterpreter's
      # own DISPATCH_ORDER is; see that constant's doc comment for why this is
      # hand-typed rather than read live off the meta-domain at every dispatch.
      # Shorter than the aggregate order for the same reasons the declaration
      # itself gives : no refuse_unknown_arguments/refuse_absent_arguments (an
      # entity inherits its aggregate's own gate) and no
      # assign_creation_attributes (an entity is never created through this
      # path).
      DISPATCH_ORDER = Hecksagain::Vocabulary.symbols("EntityDispatchOrder")

      # `instance` is the PARENT aggregate record (what gets saved and
      # returned) ; `element`/`view` are the entity piece itself — `view`
      # wraps `element` as it stood at `locate_element`, pre-mutation, and
      # `enforce_ensures` builds its own settled wrapper off `element` as it
      # stands after, the same split the original sequential code made.
      #
      # `chain` — S17, ADR 0026 — every entity the dotted verb passes
      # through, root-first (`[Handler, Dispatch]` for `Handler.Dispatch.
      # Bind`) ; `entity`/`entity_name` stay the CHAIN'S OWN LAST entry,
      # the one a command actually belongs to and a mutation actually
      # targets, so every step written before this ADR (enforce_givens,
      # apply_mutations, advance_lifecycle, element_identity, ...) reads
      # exactly as it always has. Only `locate_element` walks the chain.
      Context = Struct.new(:domain, :aggregate, :entity, :entity_name, :command, :command_name,
                           :args, :repository, :instance, :chain, :element, :view, :transition,
                           :old_element, :result)

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, dotted, args)
        *entity_names, command_name = dotted.to_s.split(".")
        if entity_names.empty?
          raise UnknownVerb, RefusalWording.render("UnknownVerb", "entity_unknown",
                                                   aggregate: aggregate.hecks_name, entity: dotted.to_s.inspect)
        end

        chain  = walk_entity_chain(aggregate, entity_names)
        entity = chain.last
        command = entity.command(command_name) ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_no_command",
                                                           entity: entity.hecks_name, command: command_name.inspect))

        ctx = Context.new(domain, aggregate, entity, entity_names.join("."), command, command_name, args)
        ctx.chain = chain
        run_dispatch_order(DISPATCH_ORDER, ctx)
        [ctx.instance, ctx.result]
      end

      private

      # ONE HOP PER DOTTED SEGMENT — `ProcessManager.Handler.Dispatch.Bind`
      # (once the dispatcher has already stripped "Domain::Aggregate.")
      # walks Handler off the aggregate, then Dispatch off Handler, each
      # step reading `.entities` exactly the way the single-level case
      # always did — a nested entity is "structurally interchangeable
      # with an aggregate" (Entity's own header) for precisely this
      # reason. Two levels is what Handler/Dispatch need today ; nothing
      # here assumes it stops at two.
      def walk_entity_chain(aggregate, entity_names)
        owner = aggregate
        entity_names.map do |name|
          found = owner.entities.find { |piece| piece.hecks_name == name } ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_unknown",
                                                           aggregate: owner.hecks_name, entity: name.inspect))
          owner = found
          found
        end
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

      def step_hydrate_parent(ctx)
        ctx.repository = @registry.repository(ctx.domain, ctx.aggregate)
        ctx.instance = step(:hydrate_parent) {
          parent(ctx.repository, ctx.aggregate, ctx.entity_name, ctx.command_name, ctx.args)
        }
      end

      def step_locate_element(ctx)
        ctx.element = step(:locate_element) {
          EntityElement.locate_chain(ctx.aggregate, ctx.chain, ctx.instance, ctx.args, ctx.command_name)
        }
        # `view` was hydrated ONCE, here, into its OWN state hash
        # (Value.hydrate builds a fresh Hash — never aliased with `element`)
        # — exactly right for enforce_givens, which must read pre-mutation.
        ctx.view = Instance.new(aggregate: ctx.entity, id: EntityElement.element_identity(ctx.entity, ctx.element).to_s,
                                state: ctx.element)
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) {
          @rules.enforce_givens(ctx.view, ctx.command, ctx.args, domain: ctx.domain, declaring: ctx.entity, parent: ctx.instance)
        }
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.entity, ctx.command, ctx.view) }
      end

      def step_apply_mutations(ctx)
        ctx.old_element = ctx.element.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) {
          ctx.command.mutations.each { |mutation|
            EntityElement.apply_to_element(@rules, ctx.aggregate, ctx.entity, ctx.element, mutation, ctx.args)
          }
        }
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.element[ctx.entity.lifecycle.field] = ctx.transition.target }
      end

      # An ensures reads the SETTLED record, so it needs a view hydrated from
      # `element` as it stands now, mutations included — unlike `view` above,
      # built once and read pre-mutation by enforce_givens.
      def step_enforce_ensures(ctx)
        step(:enforce_ensures) do
          settled = Instance.new(aggregate: ctx.entity, id: ctx.view.id, state: ctx.element)
          @rules.enforce_ensures(settled, ctx.command, ctx.args, old: ctx.old_element, domain: ctx.domain, parent: ctx.instance)
        end
      end

      # THE PARENT AGGREGATE's own invariants — `ctx.instance` is the
      # parent record an entity mutation writes into (this file's own
      # `Context` comment), the SAME boundary an aggregate-level
      # invariant guards regardless of which interpreter changed it. No
      # separate "entity invariant" exists (S10, ADR 0025 scopes
      # `invariant` to the aggregate only) — see `Admissibility#
      # enforce_invariants`'s own comment.
      def step_enforce_invariants(ctx)
        step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
      end

      def step_save(ctx)
        step(:save) { ctx.repository.save(ctx.instance) }
      end

      def step_emit(ctx)
        ctx.result = step(:emit) { @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository) }
      end

      # THE PARENT AGGREGATE, addressed exactly as `CommandInterpreter#hydrate`
      # addresses one acting on itself — derive from the declared identity first
      # (`Identity.of`), and let a bare `id:` name an already-derived record when
      # the identity itself is not what the caller is holding.
      def parent(repository, aggregate, entity_name, command_name, args)
        parent_id = Identity.of(aggregate, args) ||
                    Identity.from(aggregate, args, :id) ||
                    raise(NotFound, RefusalWording.render("NotFound", "entity_parent_no_identity",
                                                          command: command_name, aggregate: aggregate.hecks_name,
                                                          entity: entity_name, identity: Identity.reading(aggregate)))
        found = repository.find(parent_id) ||
                raise(NotFound, RefusalWording.render("NotFound", "record_missing",
                                                      aggregate: aggregate.hecks_name,
                                                      identity:  Identity.reading(aggregate),
                                                      offered:   Rendering.describe(parent_id)))
        found.dup
      end

      # `locate_chain`/`element_of`/`element_identity`/`apply_to_element` and
      # their own helpers used to live here — moved to `Runtime::EntityElement`
      # (see that file's own header) so `CommandInterpreter`'s own
      # `delegate_to_entity` step can locate and mutate the same element the
      # same way, against an aggregate record already held in memory. `call`,
      # above, and every `step_*` method reach them through that module now;
      # nothing about the STEPS themselves changed.
    end
  end
end
