require_relative "interpreting"
require_relative "../naming"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "value"
require_relative "refusal_wording"

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
      Context = Struct.new(:domain, :aggregate, :entity, :entity_name, :command, :command_name,
                            :args, :repository, :instance, :element, :view, :transition, :old_element, :result)

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, dotted, args)
        entity_name, command_name = Naming.split_dotted(dotted)
        entity  = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_unknown",
                                                            aggregate: aggregate.hecks_name, entity: entity_name.inspect))
        command = entity.command(command_name) ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_no_command",
                                                            entity: entity_name, command: command_name.inspect))

        ctx = Context.new(domain, aggregate, entity, entity_name, command, command_name, args)
        run_dispatch_order(DISPATCH_ORDER, ctx)
        [ctx.instance, ctx.result]
      end

      private

      def step_normalize_args(ctx)
        ctx.args = step(:normalize_args) { normalize_args(ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_refuse_role_mismatch(ctx)
        step(:refuse_role_mismatch) { @rules.refuse_role_mismatch(ctx.command) }
      end

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.command, ctx.args) }
      end

      def step_hydrate_parent(ctx)
        ctx.repository = @registry.repository(ctx.domain, ctx.aggregate)
        ctx.instance = step(:hydrate_parent) { parent(ctx.repository, ctx.aggregate, ctx.entity_name, ctx.command_name, ctx.args) }
      end

      def step_locate_element(ctx)
        ctx.element = step(:locate_element) { element_of(ctx.aggregate, ctx.entity, ctx.entity_name, ctx.command_name, ctx.instance, ctx.args) }
        # `view` was hydrated ONCE, here, into its OWN state hash
        # (Value.hydrate builds a fresh Hash — never aliased with `element`)
        # — exactly right for enforce_givens, which must read pre-mutation.
        ctx.view = Instance.new(aggregate: ctx.entity, id: element_identity(ctx.entity, ctx.element).to_s, state: ctx.element)
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) { @rules.enforce_givens(ctx.view, ctx.command, ctx.args) }
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.entity, ctx.command, ctx.view) }
      end

      def step_apply_mutations(ctx)
        ctx.old_element = ctx.element.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) { ctx.command.mutations.each { |mutation| apply_to_element(ctx.aggregate, ctx.entity, ctx.element, mutation, ctx.args) } }
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
          @rules.enforce_ensures(settled, ctx.command, ctx.args, old: ctx.old_element)
        end
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
                                                       identity: Identity.reading(aggregate),
                                                       offered: Rendering.describe(parent_id)))
        found.dup
      end

      # ONE ELEMENT, MATCHED ON EVERY PART OF ITS IDENTITY — not just the first.
      # A piece's identity may be several paths, the same shape a head's can be,
      # so a dispatch that names the element has to supply every part and every
      # part has to agree with the stored one.
      def element_of(aggregate, entity, entity_name, command_name, instance, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_holds_no_list",
                                                              aggregate: aggregate.hecks_name, entity: entity_name))

        wants = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          raw  = args[head] ||
                 raise(NotFound, RefusalWording.render("NotFound", "entity_element_no_identity",
                                                        command: command_name, entity: entity_name,
                                                        identity: Identity.reading(entity)))

          [head, path, Value.for_attribute(aggregate, entity.attribute(head), raw)]
        end

        original = Array(instance[list_attr.name])
        position = original.find_index { |el| wants.all? { |head, _path, want| el[head] == want } }
        unless position
          raise NotFound, RefusalWording.render(
            "NotFound", "entity_element_missing",
            entity: entity_name, identity: Identity.reading(entity),
            wants: wants.map { |_h, path, want| Identity.scalar(path, want) }.join(", "),
            aggregate: aggregate.hecks_name, parent_id: instance.id.inspect
          )
        end

        # ONE LEVEL DEEPER THAN Instance#dup, for the same reason: a list
        # attribute holds Hashes, and `apply_to_element` mutates the found
        # one IN PLACE — the update mechanism for an entity, not a bug. But
        # in place means aliased with the adapter's own record until this
        # copies the array and the target element before handing either
        # back, and writes the fresh array into `instance` so the copy is
        # what persists on success and NOTHING aliased survives a refusal.
        copied  = original.dup
        element = copied[position].dup
        copied[position] = element
        instance[list_attr.name] = copied
        element
      end

      # THE ELEMENT'S OWN IDENTITY, joined from its parts — the entity-level
      # twin of `Identity.of`, reading off the STORED ELEMENT (a Hash) rather
      # than a dispatch payload. An id is a SCALAR, and the PATH is how it is
      # reached — never by opening a value object and taking whatever single
      # field is inside. That unwrapping is gone from the language : a piece
      # that does not name its fields is refused when the bluebook loads ("an
      # entity says what it is known by", "an identity part reaches a scalar"),
      # so by the time a dispatch arrives here there is always a path to dig.
      def element_identity(entity, element)
        parts = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          Identity.scalar(path, element[head])
        end

        Naming.identity(parts)
      end

      def apply_to_element(aggregate, entity, element, mutation, args)
        case mutation.op
        when :set
          value = @rules.resolve_source(mutation.source, args)
          attribute = entity.attribute(mutation.target)
          element[mutation.target] = attribute ? Value.for_attribute(aggregate, attribute, value) : value
        when :increment, :decrement
          attribute = entity.attribute(mutation.target)
          amount    = @rules.resolve_source(mutation.source, args)
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute
          element[mutation.target] = @rules.arithmetic(
            element[mutation.target],
            amount,
            mutation.target,
            @rules.sign_of(mutation.op)
          )
        end
      end
    end
  end
end
