# frozen_string_literal: true

require "tempfile"
require_relative "../../child"

module Hecks
  module QualityControlCli
    class QaSweep
      module AllMode
        # The child processes of `--all`: how each one is spawned, and the pool that keeps a bounded
        # number of them alive at once.
        module Children
          # The flags a child sweep is given besides its target and modes: `seeds` and `steps`
          # forward only when set, so each child derives its own depth from its own streak.
          ChildFlags = Struct.new(:seeds, :steps, :self_consistency)

          private

          # Spawns `hecks quality_control query sweep.run target=<target>` as a fresh process, not a
          # fork.
          def spawn_sweep_child(target_reference, flags, modes:, parity: false)
            # Unlinked at once: the open fd stays readable, nothing is left on disk, and no fixed
            # path collides.
            log = Tempfile.new(["qa_sweep-#{filesystem_safe_component(target_reference)}-", ".log"])
            log.unlink

            args = child_args(target_reference, flags, modes, parity)
            pid = Process.spawn(*Child.argv(@root, "qa_sweep", *args), out: log, err: log, chdir: @root)
            { target: target_reference, pid: pid, log: log }
          end

          def child_args(target_reference, flags, modes, parity)
            args = [target_reference]
            args += ["--seeds", flags.seeds.to_s] if flags.seeds
            args += ["--steps", flags.steps.to_s] if flags.steps
            args += ["--adversarial", @adversarial.to_s, "--self-consistency", flags.self_consistency.to_s]
            args += ["--role-draw", @role_draw.to_s, "--dry-run", @dry_run.to_s]
            args + (parity ? ["--persistence-parity"] : ["--modes", modes.join(",")])
          end

          def collect_sweep_child(child, status)
            child[:log].rewind
            output = child[:log].read
            child[:log].close

            { target: child[:target], exit_status: status.exitstatus, termsig: status.termsig, output: output }
          end

          # Keeps at most `@max_parallel` children alive; results come back in queue order so
          # reports are stable. The block spawns the child for one target.
          def run_pool(targets, &)
            pending = targets.dup
            running = {}
            results = {}

            until pending.empty? && running.empty?
              fill_pool(pending, running, &)
              reap_child(running, results)
            end

            targets.map { |target| results.fetch(target) }
          end

          def fill_pool(pending, running)
            while running.size < @max_parallel && (next_target = pending.shift)
              child = yield(next_target)
              running[child[:pid]] = child
            end
          end

          def reap_child(running, results)
            pid, status = Process.wait2(-1)
            child = running.delete(pid)
            results[child[:target]] = collect_sweep_child(child, status) if child
          end
        end
      end
    end
  end
end
