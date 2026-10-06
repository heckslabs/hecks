require_relative "../../rendering"
require_relative "../entity_element"
require_relative "../errors"
require_relative "../identity"
require_relative "../instance"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class EntityInterpreter
      # Finds the parent aggregate record and the entity element a command addresses inside it.
      # Mixed into {EntityInterpreter}.
      module Locating
        private

        def step_hydrate_parent(ctx)
          # `ctx.repository` is resolved once, in `#call`, before the
          # isolation decision — not here.
          ctx.instance = step(:hydrate_parent) { parent_record(ctx) }
        end

        def step_locate_element(ctx)
          ctx.element = step(:locate_element) do
            EntityElement.locate_chain(ctx.aggregate, ctx.chain, ctx.instance, ctx.args, ctx.command_name, ctx.route)
          end
          # `view` was hydrated once, here, into its own state hash
          # (Value.hydrate builds a fresh Hash — never aliased with `element`)
          # — exactly right for enforce_givens, which must read pre-mutation.
          ctx.view = element_view(ctx)
        end

        def element_view(ctx)
          Instance.new(aggregate: ctx.entity, id: EntityElement.element_identity(ctx.entity, ctx.element).to_s,
                       state: ctx.element)
        end

        # Finds the parent aggregate: the declared identity first, then a bare
        # `id:` for a record the caller derived itself.
        def parent_record(ctx)
          parent_id = parent_identity(ctx)
          aggregate = ctx.aggregate
          found = ctx.repository.find(parent_id) ||
                  raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                             aggregate: aggregate.hecks_name,
                                                             identity:  Identity.reading(aggregate),
                                                             offered:   Rendering.describe(parent_id)))
          found.dup
        end

        def parent_identity(ctx)
          aggregate = ctx.aggregate
          ctx.route&.aggregate ||
            Identity.of(aggregate, ctx.args) ||
            Identity.from(aggregate, ctx.args, :id) ||
            raise(NotFound, RefusalWording.render_site("NotFound", "entity_parent_no_identity",
                                                       command: ctx.command_name, aggregate: aggregate.hecks_name,
                                                       entity: ctx.entity_name, identity: Identity.reading(aggregate)))
        end
      end
    end
  end
end
