require_relative "../errors"
require_relative "../identity"
require_relative "../instance"
require_relative "../refusal_wording"
require_relative "../dependency_planning"
require_relative "../../rendering"

module Hecks
  module Runtime
    class CommandInterpreter
      # Finds or builds the record a command acts on, and refuses when the identity it names is
      # missing, occupied or contradicts its route.
      module Hydration
        private

        # Picks the hydration the command's dependency plan allows.
        def hydrate_for(ctx)
          if ctx.plan.complete_state? && ctx.plan.state_independent?
            hydrate_complete_state(ctx)
          elsif ctx.plan.complete_state?
            hydrate_prior_or_initial(ctx)
          elsif legacy_implicit_creation?(ctx)
            hydrate_legacy_creation(ctx)
          else
            hydrate_existing(ctx)
          end
        end

        # The record an acting command names, by route or by the identity its arguments carry.
        def hydrate_existing(ctx)
          id = ctx.route ? ctx.route.aggregate : acting_identity(ctx)
          (ctx.repository.find(id) || raise_record_missing(ctx.aggregate, id)).dup
        end

        # The identity an acting command's arguments carry, by its own facts, `id`, or its
        # reference key.
        def acting_identity(ctx)
          aggregate = ctx.aggregate
          identity_of(aggregate, ctx.args) ||
            identity_from(aggregate, ctx.args, :id) ||
            identity_from(aggregate, ctx.args, reference_key(ctx.command)) ||
            raise(NotFound, RefusalWording.render_site("NotFound", "acting_no_identity",
                                                       command: ctx.command.hecks_name, aggregate: aggregate.hecks_name,
                                                       identity: identity_reading(aggregate)))
        end

        # Transitional compatibility for a command that has not yet acquired
        # explicit effects — isolated from the normal routing/planning path so
        # `reference_to` does not choose how a migrated command hydrates. An
        # un-migrated command routes here on `creates?` alone, regardless of
        # whether it has any mutations; requiring an empty write_set here would
        # wrongly exclude one that sets fields.
        def legacy_implicit_creation?(ctx)
          ctx.route.nil? && ctx.command.creates?
        end

        def hydrate_legacy_creation(ctx)
          id = identity_of(ctx.aggregate, ctx.args) || raise_creating_no_identity(ctx.command, ctx.aggregate)
          raise_already_exists(ctx.command, ctx.aggregate, id) if ctx.repository.find(id)

          fresh_instance(ctx, id)
        end

        def hydrate_complete_state(ctx)
          id = creation_identity(ctx)
          # `creates?` on an occupied identity refuses (`AlreadyExists`), except
          # under ATOMIC_PUT: that adapter enforces the same refusal itself,
          # atomically, via `insert_only:` in `step_save` — reading here too
          # would race the write for nothing.
          if ctx.command.creates? && ctx.strategy != DependencyPlanning::ATOMIC_PUT && ctx.repository.find(id)
            raise_already_exists(ctx.command, ctx.aggregate, id)
          end

          fresh_instance(ctx, id)
        end

        # A complete command may still depend on prior state (lifecycle guards
        # are the common case) — read once, so an existing record is checked
        # against its real state rather than assumed defaults.
        def hydrate_prior_or_initial(ctx)
          id    = creation_identity(ctx)
          found = ctx.repository.find(id)
          # Same refusal as `hydrate_complete_state`, for a complete-but-state-
          # dependent command (one with a `given` on its own prior state).
          # Gated on `creates?`: a non-creating command's complete payload just
          # means "act on whatever this identity already holds".
          raise_already_exists(ctx.command, ctx.aggregate, id) if found && ctx.command.creates?

          found ? found.dup : fresh_instance(ctx, id)
        end

        # The identity a complete command's facts derive, checked against its route.
        def creation_identity(ctx)
          derived = identity_of(ctx.aggregate, ctx.args)
          refuse_route_mismatch(ctx.command, ctx.route, derived) if ctx.route && derived
          ctx.route&.aggregate || derived || raise_creating_no_identity(ctx.command, ctx.aggregate)
        end

        def refuse_route_mismatch(command, route, derived)
          return if route.aggregate.to_s == derived.to_s

          raise TypeMismatch,
                "#{command.hecks_name} routes to #{route.aggregate.inspect}, but its identity facts name #{derived.inspect}"
        end

        def fresh_instance(ctx, id)
          Instance.new(aggregate: ctx.aggregate, id: id, args: ctx.args)
        end

        def raise_already_exists(command, aggregate, id)
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                          identity: identity_reading(aggregate),
                                                          offered: Rendering.describe(id)))
        end

        def raise_record_missing(aggregate, id)
          raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                     aggregate: aggregate.hecks_name,
                                                     identity:  identity_reading(aggregate),
                                                     offered:   Rendering.describe(id)))
        end

        def raise_creating_no_identity(command, aggregate)
          raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                     command:   command.hecks_name,
                                                     aggregate: aggregate.hecks_name,
                                                     identity:  identity_reading(aggregate)))
        end

        # Shared with `EntityInterpreter`, in `Runtime::Identity`, rather than
        # kept as two copies that could only ever drift.
        def identity_of(aggregate, args)   = Identity.of(aggregate, args)
        def identity_from(aggregate, args, key) = Identity.from(aggregate, args, key)
        def identity_reading(construct)    = Identity.reading(construct)
      end
    end
  end
end
