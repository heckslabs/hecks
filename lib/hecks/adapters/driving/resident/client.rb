require "socket"
require "rbconfig"
require "fileutils"
require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/wire"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The launcher's first step: ask the checkout's resident to run the line, and end with its
        # status. A launcher with no resident to ask, or one that cannot serve the line, goes on and
        # boots as it always has, and starts a resident for the next line.
        #
        # It uses only the standard library, never `json`: it runs before `bundler/setup`, and a
        # `json` loaded first would not be the version the Gemfile pins.
        module Client
          # Lines the launcher runs itself, since they need the terminal or run until interrupted.
          BYPASSED = %w[console interview init mcp].freeze
          # Seconds the resident has to accept the line before the launcher boots on its own.
          HANDSHAKE = 3
          # What a socket that is gone or refused raises.
          LOST = [SystemCallError, IOError].freeze

          module_function

          # @param script [String] the launcher's own path (`__FILE__`)
          # @return [void] ends the process with the line's status when the resident ran it
          def run(script)
            return if defined?(::Hecks::Adapters::Driving::Resident::CHILD) || bypass?

            root = Paths.root_for(script)
            return unless Paths.usable?(root)

            status = ask(root, script)
            exit(status) if status
            spawn_resident(root, script)
          rescue *LOST
            nil
          end

          # @return [Boolean] whether this line is one the launcher runs itself
          def bypass?
            disabled = ENV.fetch("HECKS_NO_RESIDENT", "")
            return true unless disabled.empty? || disabled == "0"

            BYPASSED.include?(ARGV.first.to_s.chomp("!")) || ARGV.include?("--stream")
          end

          # @return [Integer, nil] the line's exit status, or nil when the resident did not take it
          def ask(root, script)
            socket = UNIXSocket.new(Paths.socket(root))
            Wire.write_request(socket, request(script))
            [$stdin, $stdout, $stderr].each { |stream| socket.send_io(stream) }
            accepted?(socket) ? finish(socket) : nil
          rescue *LOST
            nil
          end

          # @return [Boolean] whether the resident said it would run the line
          def accepted?(socket) = socket.wait_readable(HANDSHAKE) && Wire.read_reply(socket) == Wire::GO

          # @return [Integer] the status the resident reports once it has the line; 1 if it vanishes
          def finish(socket)
            reply = Wire.read_reply(socket).to_s
            reply.start_with?(Wire::STATUS) ? Integer(reply.delete_prefix(Wire::STATUS)) : 1
          rescue *LOST, ArgumentError
            1
          end

          # @return [Hash] the line as the resident needs it
          def request(script)
            { argv: ARGV.dup, cwd: Dir.pwd, env: ENV.to_h, script: File.realpath(script) }
          end

          # Starts the resident that will serve the next line; it takes its own lock, so a second
          # start exits at once.
          def spawn_resident(root, script)
            return if lock_held?(root)

            server = File.join(__dir__, "server.rb")
            lib = File.expand_path("../../../..", __dir__)
            quiet = { in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true }
            Process.detach(Process.spawn(RbConfig.ruby, "-I", lib, server, root, File.realpath(script), **quiet))
          end

          # @return [Boolean] whether a resident holds the checkout's lock, so it is up or coming up
          def lock_held?(root)
            FileUtils.mkdir_p(Paths.directory, mode: 0o700)
            File.open(Paths.lock(root), File::CREAT | File::RDWR, 0o600) do |lock|
              return !lock.flock(File::LOCK_EX | File::LOCK_NB)
            end
          rescue SystemCallError
            true
          end
        end
      end
    end
  end
end
