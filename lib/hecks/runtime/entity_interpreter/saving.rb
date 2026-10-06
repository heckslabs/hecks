require_relative "../../rendering"
require_relative "../errors"
require_relative "../identity"

module Hecks
  module Runtime
    class EntityInterpreter
      # The save and emit steps: the parent record is written, and its events announced, with the
      # root aggregate's name and the parent's identity. Mixed into {EntityInterpreter}.
      module Saving
        private

        # `dry_run:` skips only the persist — the reference-existence check
        # above stays unconditional either way.
        def step_save(ctx)
          step(:save) { @rules.resolve_state_references(ctx.domain, ctx.aggregate, ctx.instance.state) }

          return if ctx.dry_run

          step(:save) { persist_parent(ctx) }
        end

        def persist_parent(ctx)
          # `expected_version:` is nil for a non-CAS repository or an instance
          # never read from storage — either falls through to a plain save.
          ctx.persistence_outcome = ctx.repository.save(ctx.instance, expected_version: ctx.instance.version)
          raise_lost_race(ctx) if ctx.persistence_outcome.status == :stale
        end

        # Intentionally not a `RefusalWording.render` call — see `Runtime::StaleWrite`'s own
        # comment.
        def raise_lost_race(ctx)
          raise(StaleWrite,
                "#{ctx.command.hecks_name} on #{ctx.aggregate.hecks_name} " \
                "(#{Identity.reading(ctx.aggregate)}: #{Rendering.describe(ctx.instance.id)}) lost a race — " \
                "another write committed against this record after it was read")
        end

        # `dry_run:` skips this too — nothing was committed, so `ctx.result`
        # stays nil and `Dispatcher#dry_run?` never reads it.
        def step_emit(ctx)
          return if ctx.dry_run

          ctx.result = step(:emit) { @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository) }
        end
      end
    end
  end
end
