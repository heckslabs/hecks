require "socket"
require "rbconfig"
require "fileutils"
require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/wire"
require "hecks/adapters/driving/resident/peer"
require "hecks/adapters/driving/resident/crowd"
require "hecks/adapters/driving/resident/claim"
require "hecks/adapters/driving/resident/outcome"
require "hecks/adapters/driving/resident/stuck"

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
          # Long-running servers, by their plain names (no underscores, lower case, no `!`): under a
          # resident each would be a child with a client waiting above it, for days, and a board
          # that restarts itself would leave a waiting client behind at every restart.
          SERVING = %w[pipelineboard.serve server.present server.compose server.preview
                       server.servequeryirmcp].freeze
          # The namespace a command word may be written with.
          NAMESPACE = "Hecks::".freeze
          # Seconds the resident has, once it has said `fds`, to take the streams and say `ready`,
          # and to take the request itself, before the launcher boots on its own.
          HANDSHAKE = 3
          # Seconds an idle resident has to answer a request, until a resident has written the
          # Hecks world's `ready_wait_ms`. A resident that has not answered by then is busy, and
          # booting on its own costs less than waiting for it.
          READY_WAIT = 0.4
          # What a socket that is gone, refused or too slow raises.
          LOST = [SystemCallError, IOError].freeze

          module_function

          # @param script [String] the launcher's own path (`__FILE__`)
          # @return [void] ends the process with the line's status when the resident ran it
          def run(script)
            return if defined?(::Hecks::Adapters::Driving::Resident::CHILD)
            return Outcome.note(Outcome::BYPASS) if bypass?

            root = Paths.root_for(script)
            reason = Paths.unusable_reason(root)
            Outcome.note(reason ? unusable(reason) : attempt(root, script))
          rescue *LOST
            Outcome.note(Outcome::NONE)
          end

          # @return [String] the outcome for a root no resident may serve
          def unusable(reason) = reason == "unstable" ? Outcome::UNSTABLE : Outcome.refused(reason)

          # Asks the resident, ends the process with its status when it ran the line, and otherwise
          # starts one for the next line, whether or not one refused this line: a resident whose
          # code changed has retired, and the next line needs a new one.
          #
          # @return [String] the outcome when the launcher goes on to boot on its own: the reason a
          #   resident gave for not serving the line, else what starting one came to
          def attempt(root, script)
            status, why = ask(root, script)
            Stuck.after(root, why)
            exit(status) if status
            spawned = spawn_resident(root, script)
            why ? Outcome.refused(why) : spawned
          end

          # @return [Boolean] whether this line is one the launcher runs itself
          def bypass?
            disabled = ENV.fetch("HECKS_NO_RESIDENT", "")
            return true unless disabled.empty? || disabled == "0"

            BYPASSED.include?(ARGV.first.to_s.chomp("!")) || ARGV.include?("--stream") || serving?
          end

          # @return [Boolean] whether the line starts one of the long-running servers
          def serving? = ARGV.first(2).any? { |word| SERVING.include?(plain(word)) }

          # @return [String] a command word as the launcher spells it however it was typed:
          #   `Hecks::PipelineBoard.serve!` and `pipeline_board.serve` are `pipelineboard.serve`
          def plain(word)
            bare = word.to_s.delete_prefix(NAMESPACE)
            bare.delete("_").downcase.chomp("!")
          end

          # Asks the resident to run the line. The socket is closed whatever happens, before the
          # launcher boots on its own, so a resident that is slow never runs a line this launcher
          # then runs itself.
          #
          # @return [Array(Integer, nil), Array(nil, String)] the line's exit status and nil, or nil
          #   and why the resident did not take it (nil when there was nothing to ask)
          def ask(root, script)
            return [nil, Paths.absent_reason(root)] unless Paths.trusted_socket?(root)

            socket = UNIXSocket.new(Paths.socket(root))
            Peer.trusted?(socket) ? converse(socket, script, ready_wait) : [nil, "unsafe"]
          rescue Wire::Slow
            [nil, "busy"]
          rescue *LOST, Wire::Refused
            [nil, nil]
          ensure
            socket&.close
          end

          # Sends the line and waits for `fds` (at most `wait` seconds: an idle resident answers in
          # milliseconds), sends the three streams only then (so nothing the resident reads of the
          # request can take one with it), waits for `ready`, answers `go` and waits for the status.
          # A `stale` in place of `fds` sends the launcher on to boot.
          def converse(socket, script, wait = READY_WAIT)
            Wire.write_request(socket, request(script), seconds: HANDSHAKE)
            first = first_word(socket, wait)
            return [nil, refusal(first)] unless first == Wire::FDS

            [$stdin, $stdout, $stderr].each { |stream| socket.send_io(stream) }
            word = answer(socket)
            return [nil, refusal(word)] unless word == Wire::READY

            Wire.reply(socket, Wire::GO)
            [finish(socket), nil]
          end

          # @return [String] the resident's first word on the request: `fds`, `stale:<reason>`,
          #   `dropped:deadline` (it gave up on a slow caller), or `dropped:closed` when it hung up
          # @raise [Wire::Slow] when it said nothing in time
          def first_word(socket, wait = READY_WAIT)
            Wire.read_line(socket, wait)
          rescue EOFError
            "dropped:closed"
          end

          # @return [String] what the resident said to the request: `busy` when it said nothing in
          #   time, `dropped:closed` when it hung up
          def answer(socket)
            return "busy" unless socket.wait_readable(HANDSHAKE)

            Wire.read_reply(socket) || "dropped:closed"
          end

          # @return [Float] seconds to wait for a resident's first word: the Hecks world's
          #   `ready_wait_ms`, as the last resident wrote it, never above the handshake
          def ready_wait
            [Paths.recall("ready_wait_ms", READY_WAIT * 1000) / 1000.0, HANDSHAKE].min
          end

          # @return [String] the reason a reply that was not `ready` gives: `stale:env` is `env`
          def refusal(word) = word.delete_prefix("#{Wire::STALE}:")

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

          # Starts the resident that will serve the next line, unless the cap of residents is met;
          # it takes its own lock, so a second start exits at once. It leaves the launcher's
          # session, so it keeps no terminal.
          #
          # @return [String] the outcome: `started`, `none` when one is already coming up (its lock
          #   is held, or another launcher has claimed the start), or `refused:crowded`
          def spawn_resident(root, script)
            return Outcome::NONE if lock_held?(root)
            return Outcome.refused("crowded") if Crowd.crowded?(root)
            return Outcome::NONE unless Claim.take?(root)

            server = File.join(__dir__, "server.rb")
            lib = File.expand_path("../../../..", __dir__)
            quiet = { in: File::NULL, out: File::NULL, err: File::NULL }
            Process.detach(Process.spawn(RbConfig.ruby, "-I", lib, server, root, File.realpath(script), **quiet))
            Outcome::STARTED
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
