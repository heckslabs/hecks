module Hecks
  module Adapters
    module Driving
      module Resident
        # The threads of a resident: one accepts callers, a pool of workers takes each through its
        # handshake, and one does the upkeep between lines. A caller that is slow, or a resident
        # busy with a fork, therefore holds up no other caller. Only the fork itself, and the
        # loading of what children found missing, take turns, under one lock, so a fork never
        # copies the resident halfway through a load.
        module Pool
          # Seconds a caller may wait in the queue before a worker takes it. A caller waits for the
          # resident's first word for less than this (the world's `ready_wait_ms`), so one that has
          # waited longer has booted on its own, and is dropped unread.
          QUEUE_WAIT = 1.0
          # Seconds between rounds of upkeep.
          UPKEEP_SECONDS = 0.5

          private

          # The locks and queues the threads share: `@guard` for the lists of what is held and
          # running, `@fork_lock` for the forks and for loading, `@queue` for callers waiting.
          def setup_pool
            @guard = Mutex.new
            @fork_lock = Mutex.new
            @held = []
            @queue = Queue.new
            @workers = []
          end

          # Takes one waiting caller, if any comes within a second, and queues it for a worker.
          def accept
            return unless @server.wait_readable(1.0)

            client = @server.accept_nonblock(exception: false)
            enqueue(client) unless client == :wait_readable
          end

          def enqueue(client)
            hold(client)
            @queue << [client, now]
          end

          def start_threads
            count = [Integer(@settings.fetch(:workers, Loading::DEFAULTS[:workers])), 1].max
            @workers = Array.new(count) { Thread.new { work } }
            @upkeep = Thread.new { upkeep }
          end

          def work
            while (job = @queue.pop)
              client, queued = job
              now - queued > QUEUE_WAIT ? drop(client, []) : handle(client)
            end
          end

          def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # What the resident does between lines: reaps finished lines, loads what children named
          # as missing (while no child is being forked), watches the code and the declarations, and
          # retires when they change or the checkout is gone.
          def upkeep
            until @retired
              sleep(UPKEEP_SECONDS)
              @guard.synchronize { @monitors.select!(&:alive?) }
              @fork_lock.synchronize { learn } unless @notes.empty?
              @changed ||= @fingerprint.changed?
              @changed ? retire : retire_when_orphaned
            end
          rescue StandardError
            nil
          end

          # Whether the code or the declarations have changed. The upkeep thread watches them, so
          # a line never pays for the look; a resident without one (a spec's) looks for itself.
          def changed? = @upkeep ? @changed : @fingerprint.changed?

          # Whether no caller is being served, no line is running, and the idle time has passed.
          def idle?
            return false if @guard.synchronize { @held.any? || @monitors.any?(&:alive?) }

            Time.now - @active > @settings[:idle_seconds]
          end

          # Notes a socket or stream received from a caller, so a child forked meanwhile can close
          # the ones that are not its own.
          #
          # @return [IO] the same io
          def hold(io)
            @guard.synchronize { @held << io }
            io
          end

          def release(io) = @guard.synchronize { @held.delete(io) }

          # Waits for the workers and the upkeep, which end when the resident retires.
          def join_threads
            @queue.close
            [*@workers, @upkeep].compact.each { |thread| thread.join(6) }
          end
        end
      end
    end
  end
end
