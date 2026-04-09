# Hecks::Runtime::Actor::Supervisor
#
# Monitors actor mailboxes and restarts them on failure.
# Two strategies: :restart (recreate the mailbox) and :stop
# (let it die). Configurable per aggregate or globally.
#
#   supervisor = Supervisor.new(strategy: :restart, max_restarts: 3)
#   supervisor.watch(mailbox)
#   supervisor.on_failure { |agg, error| log(error) }
#
module Hecks
  class Runtime
    module Actor
      class Supervisor
        attr_reader :strategy, :max_restarts

        def initialize(strategy: :restart, max_restarts: 3)
          @strategy = strategy
          @max_restarts = max_restarts
          @watched = {}
          @restart_counts = Hash.new(0)
          @failure_handlers = []
        end

        def watch(mailbox)
          @watched[mailbox.aggregate_name] = mailbox
        end

        def on_failure(&block)
          @failure_handlers << block
        end

        # Called when a mailbox handler raises. Decides whether to restart.
        def handle_failure(aggregate_name, error)
          @failure_handlers.each { |h| h.call(aggregate_name, error) }

          case @strategy
          when :restart
            count = @restart_counts[aggregate_name] += 1
            if count <= @max_restarts
              $stderr.puts "[Supervisor] Restarting #{aggregate_name} (#{count}/#{@max_restarts})"
              true # caller should restart
            else
              $stderr.puts "[Supervisor] #{aggregate_name} exceeded max restarts"
              false
            end
          when :stop
            $stderr.puts "[Supervisor] #{aggregate_name} stopped after failure"
            false
          end
        end

        # Reset restart count (e.g., after a period of stability).
        def reset(aggregate_name)
          @restart_counts.delete(aggregate_name)
        end
      end
    end
  end
end
