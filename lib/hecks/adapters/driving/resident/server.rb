require "socket"
require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/wire"
require "hecks/adapters/driving/resident/fingerprint"
require "hecks/adapters/driving/resident/described_cache"
require "hecks/adapters/driving/resident/loading"
require "hecks/adapters/driving/resident/serving"
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
          include Serving

          # @param root [String] the checkout
          # @param script [String] the launcher the lines come from
          def self.start(root, script) = new(root, script).run

          # @param exists [#call] answers whether a path is still there; a spec stands in
          def initialize(root, script, exists: File.method(:exist?))
            @root = root
            @script = script
            @exists = exists
            @owner = Process.pid
            @monitors = []
            @notes = Queue.new
            @settings = Loading::DEFAULTS
          end

          # Takes the checkout's lock, loads, and serves lines until idle or retired.
          def run
            return unless take_lock

            prepare
            return if @crowded

            bind
            serve
          ensure
            finish if Process.pid == @owner
          end

          private

          def take_lock
            @lock = File.open(Paths.lock(@root), File::CREAT | File::RDWR, 0o600)
            @lock.flock(File::LOCK_EX | File::LOCK_NB)
          end

          def bind
            FileUtils.rm_f(Paths.socket(@root))
            @server = UNIXServer.new(Paths.socket(@root))
            File.chmod(0o600, Paths.socket(@root))
            File.write(Paths.pid(@root), Process.pid.to_s)
            @bound = true
          end

          def serve
            @active = Time.now
            settle
            until idle? || @retired
              ready = @server.wait_readable(1.0)
              learn
              ready ? handle(@server.accept) : retire_when_orphaned
            end
          end

          def idle? = @monitors.none?(&:alive?) && Time.now - @active > @settings[:idle_seconds]

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
            FileUtils.rm_f([Paths.socket(@root), Paths.pid(@root)])
            @lock&.flock(File::LOCK_UN)
          end

          def finish
            return unless @bound

            retire unless @retired
            @monitors.each(&:join)
          end
        end
      end
    end
  end
end

Hecks::Adapters::Driving::Resident::Server.start(*ARGV) if $PROGRAM_NAME == __FILE__
