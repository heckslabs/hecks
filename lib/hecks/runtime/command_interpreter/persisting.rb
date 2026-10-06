require_relative "../errors"
require_relative "../dependency_planning"
require_relative "../rebuild_sweep"
require_relative "../../rendering"

module Hecks
  module Runtime
    class CommandInterpreter
      # The save step: validates, writes the instance, and turns what the adapter answers into a
      # refusal or a retry.
      module Persisting
        private

        # `dry_run:` skips persistence, but not `resolve_state_references` or
        # the ATOMIC_PUT duplicate check (`check_dry_run_creates_duplicate`) —
        # both are validation, not persistence, and a real dispatch would
        # refuse on either before ever writing.
        def step_save(ctx)
          step(:save) { @rules.resolve_state_references(ctx.domain, ctx.aggregate, ctx.instance.state) }

          if ctx.dry_run
            step(:save) { check_dry_run_creates_duplicate(ctx) }
          else
            step(:save) { persist_and_check(ctx) }
          end
        end

        def persist_and_check(ctx)
          seed_projected_fields(ctx)
          ctx.persistence_outcome = persist_instance(ctx)
          raise_for_persistence_outcome!(ctx)
        end

        # The only path, real or dry, that catches a `creates?` command reusing
        # an occupied identity under ATOMIC_PUT — `hydrate_complete_state`
        # deliberately defers this exact check to here.
        def check_dry_run_creates_duplicate(ctx)
          return unless ctx.strategy == DependencyPlanning::ATOMIC_PUT && ctx.command.creates?
          return unless ctx.repository.find(ctx.instance.id)

          raise_already_exists(ctx.command, ctx.aggregate, ctx.instance.id)
        end

        def persist_instance(ctx)
          if ctx.strategy == DependencyPlanning::ATOMIC_PUT
            # `insert_only:` asks the adapter to refuse atomically rather than
            # this interpreter reading the record first to check — a
            # `repository.find` before every atomic_put would be exactly the
            # read this strategy exists to skip.
            ctx.repository.atomic_put(ctx.instance, insert_only: ctx.command.creates?)
          else
            # `expected_version:` is nil for a brand-new record or a
            # non-CAS repository, either of which falls through to a
            # plain, unconditional save inside `AppendOnly#save`.
            ctx.repository.save(ctx.instance, expected_version: ctx.instance.version)
          end
        end

        def raise_for_persistence_outcome!(ctx)
          case ctx.persistence_outcome.status
          when :conflicted
            raise_already_exists(ctx.command, ctx.aggregate, ctx.instance.id)
          when :stale
            # Not a declared vocabulary refusal, just a plain, informative
            # message — caught by `#call`'s retry loop, re-raised only once
            # retries are exhausted.
            raise(StaleWrite, lost_race_wording(ctx))
          end
        end

        def lost_race_wording(ctx)
          "#{ctx.command.hecks_name} on #{ctx.aggregate.hecks_name} " \
            "(#{identity_reading(ctx.aggregate)}: #{Rendering.describe(ctx.instance.id)}) lost a race — " \
            "another write committed against this record after it was read"
        end

        # The one-time, synchronous half of `projects` (ADR 0025); `RebuildSweep`
        # is what keeps a projected field current afterward. Without seeding it
        # here, a freshly created record would read a nil projected field until
        # an operator ran a sweep, refusing commands that depend on it for no
        # real reason. Uses the same `RebuildSweep.remote_value` a sweep
        # computes, and runs only at save time, never as a live read mid-dispatch.
        def seed_projected_fields(ctx)
          return if ctx.aggregate.projected_fields.empty?

          ctx.aggregate.projected_fields.each do |field|
            value = RebuildSweep.remote_value(@registry, ctx.domain, ctx.aggregate, ctx.instance.state, field)
            next if value.nil?

            ctx.instance.state[field.name] = value
          end
        end
      end
    end
  end
end
