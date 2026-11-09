require "socket"
require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/wire"
require "hecks/adapters/driving/resident/peer"
require "hecks/adapters/driving/resident/crowd"
require "hecks/adapters/driving/resident/env_trace"
require "hecks/adapters/driving/resident/fingerprint"
require "hecks/adapters/driving/resident/described_cache"
require "hecks/adapters/driving/resident/loading"
require "hecks/adapters/driving/resident/forking"
require "hecks/adapters/driving/resident/pool"
require "hecks/adapters/driving/resident/serving"
require "hecks/adapters/driving/resident/stopping"
require "hecks/adapters/driving/resident/worker"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The resident: it loads the Hecks domain once and runs each launcher line in a fork of
        # itself, so a line pays a fork and its own work, not the load. It binds no adapter and
        # opens no store, so a child sees a fresh runtime. It retires, leaving nothing behind,
        # when the code or the domain changes or after the idle time the Hecks world sets. It is
        # a cache: killing it loses nothing.
        #
        #   ruby -I lib lib/hecks/adapters/driving/resident/server.rb <checkout> <launcher script>
        class Server
          include Loading
          include Forking
          include Pool
          include Serving
          include Stopping

          # Leaves the session the launcher that started it was in, so it keeps no terminal, and
          # serves.
          #
          # @param root [String] the checkout
          # @param script [String] the launcher the lines come from
          def self.start(root, script)
            begin
              Process.setsid
            rescue SystemCallError
              nil
            end
            new(root, script).run
          end

          # @param exists [#call] answers whether a path is still there; a spec stands in
          def initialize(root, script, exists: File.method(:exist?))
            @root = root
            @script = script
            @exists = exists
            @owner = Process.pid
            @monitors = []
            @notes = Queue.new
            @settings = Loading::DEFAULTS
            setup_pool
          end

          # Takes the checkout's lock, loads, and serves lines until idle or retired.
          def run
            return unless lock_taken? && !Crowd.crowded?(@root)

            prepare
            return if @crowded

            settle
            bind
            serve
          ensure
            finish if Process.pid == @owner
          end

          private

          # Takes the checkout's lock, marks it as taken now, and clears the locks of residents that
          # are gone.
          #
          # @return [Boolean] whether the lock was free and is now this resident's
          def lock_taken?
            @lock = File.open(Paths.lock(@root), File::CREAT | File::RDWR, 0o600)
            return false unless @lock.flock(File::LOCK_EX | File::LOCK_NB)

            File.utime(nil, nil, Paths.lock(@root))
            FileUtils.rm_f(Paths.claim(@root))
            Crowd.sweep
            true
          end

          # Listens on the socket, which is made closed to everyone but this user from the start.
          def bind
            FileUtils.rm_f(Paths.socket(@root))
            @server = listen
            File.chmod(0o600, Paths.socket(@root))
            File.write(Paths.pid(@root), Process.pid.to_s)
            File.write(Paths.version(@root), "#{Wire::PROTOCOL} #{Process.pid}\n")
            @bound = true
          end

          def listen
            previous = File.umask(0o177)
            UNIXServer.new(Paths.socket(@root))
          ensure
            File.umask(previous)
          end

          # Takes callers as they come and hands each to a worker, so a caller that is slow, or a
          # resident busy with a fork, holds up no one else. Everything else the resident does
          # between lines is the upkeep thread's.
          def serve
            @active = Time.now
            start_threads
            accept until idle? || @retired
          rescue IOError, Errno::EBADF
            nil
          end

          # Whether the checkout it serves, or the socket it listens on, is gone: a worktree that
          # was retired, a temporary directory that was removed, or a cache that was cleared. A
          # resident nobody can reach, for a checkout nobody has, would only wait out the idle time.
          def orphaned? = !@exists.call(@root) || !@exists.call(Paths.socket(@root))

          # Retires when {#orphaned?}; checked once a second, when no line is waiting.
          def retire_when_orphaned = (retire if orphaned?)

          # Stops taking lines, so the next launcher starts a resident from the code as it now is.
          def retire
            @retired = true
            @server.close unless @server.closed?
            FileUtils.rm_f([Paths.socket(@root), Paths.pid(@root), Paths.version(@root)])
            @lock&.flock(File::LOCK_UN)
          end

          def finish
            return unless @bound

            retire unless @retired
            join_threads
            @monitors.each(&:join)
          end
        end
      end
    end
  end
end

Hecks::Adapters::Driving::Resident::Server.start(*ARGV) if $PROGRAM_NAME == __FILE__
