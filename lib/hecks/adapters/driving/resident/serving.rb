module Hecks
  module Adapters
    module Driving
      module Resident
        # How a resident takes one line: check who is calling, read the request, check it can serve
        # it and say `fds`, take the caller's three streams, say `ready`, and fork a child that
        # runs the line only when the caller answers `go`. The caller then waits for the child's
        # exit status.
        #
        # The `go` is what keeps a line from running twice: a caller that gave up on a slow
        # resident has closed its socket, so a request that sat in the queue meets a closed
        # connection and is dropped, not run.
        #
        # The resident takes one line at a time up to the fork, so the whole of that exchange has
        # one deadline: a caller that stalls in any step costs the other callers {HANDLE_WAIT}
        # seconds at most.
        module Serving
          # Seconds a caller has, from the moment the resident takes it, to send its request and
          # streams and to answer `ready` with `go`, before the resident drops it.
          HANDLE_WAIT = 5
          # What a caller is told when it took longer than {HANDLE_WAIT} and the resident gave up.
          DROPPED_DEADLINE = "dropped:deadline".freeze
          # How many differing variables a refusal names.
          NAMES = 3
          # Bytes the names may take: a reply is one line of at most {Wire::MAX_LINE} bytes, and
          # it opens with `stale:env:`.
          NAMES_WIDTH = 48

          private

          # Takes one caller through the handshake. Only a line that runs counts as use (see
          # {Forking#launch}): a caller that fails the handshake, whatever the reason, leaves the
          # resident as idle as it was, so a resident that no caller can use exits on its own.
          def handle(client)
            streams = []
            return drop(client, streams) unless Peer.trusted?(client)

            take(client, streams, Wire::Deadline.new(HANDLE_WAIT))
          rescue Wire::Slow
            say_dropped(client, streams)
          rescue StandardError, NoMemoryError
            drop(client, streams)
          end

          # Tells a caller that was too slow why its line was dropped, so it can tell that apart
          # from a resident that simply hung up.
          def say_dropped(client, streams)
            Wire.reply(client, DROPPED_DEADLINE)
          rescue SystemCallError, IOError
            nil
          ensure
            drop(client, streams)
          end

          # Reads the request, says `fds` if it can serve it, takes the streams and makes the offer.
          def take(client, streams, deadline)
            request = Wire.read_request(client, seconds: deadline.left)
            reason = unservable(request)
            return refuse(client, streams, reason) if reason

            Wire.reply(client, Wire::FDS)
            receive(client, streams, deadline)
            offer(client, request, streams, deadline)
          end

          # Takes the caller's standard input, output and error, each within what is left.
          def receive(client, streams, deadline)
            3.times do
              client.wait_readable(deadline.left) || raise(Wire::Slow, "the streams did not arrive")
              streams << hold(client.recv_io)
            end
          end

          # A line is served when it was made by this checkout's own launcher, with the environment
          # the code loaded under, and the code and declarations are as they were loaded; when they
          # changed, the resident retires.
          def servable?(request) = unservable(request).nil?

          # @return [String, nil] why the line cannot be served: `script` (not this checkout's
          #   launcher), `env:<NAME>` (an environment variable the code loaded under differs; the
          #   first three differing names, joined with `+`) or `changed` (the code or declarations
          #   changed, so the resident retires); nil when it can
          def unservable(request)
            return "script" unless same_script?(request)

            names = differing(request[:env])
            return "env:#{names}" if names
            return nil unless changed?

            retire
            "changed"
          end

          # @return [String, nil] the names of the first variables the line differs on from what
          #   the code loaded under, never their values, short enough to fit in a reply
          def differing(env)
            names = loaded_names.reject { |name| env[name] == @environment[name] }
            names.empty? ? nil : names.first(NAMES).join("+")[0, NAMES_WIDTH]
          end

          # The child loads the launcher the request names, so it must be this checkout's own.
          def same_script?(request) = canonical(request[:script]) == canonical(@script)

          def canonical(path)
            File.realpath(path.to_s)
          rescue SystemCallError
            File.expand_path(path.to_s)
          end

          def refuse(client, streams, reason)
            Wire.reply(client, "#{Wire::STALE}:#{reason}")
            drop(client, streams)
          end

          # Tells the caller the line can be run and runs it once the caller says `go`. A caller
          # that has gone, or says nothing in time, has its line dropped.
          def offer(client, request, streams, deadline)
            Wire.reply(client, Wire::READY)
            confirmed?(client, deadline) ? launch(client, request, streams) : drop(client, streams)
          end

          def confirmed?(client, deadline)
            Wire.read_line(client, deadline.left) == Wire::GO
          rescue SystemCallError, IOError, Wire::Refused
            false
          end

          # Closes what was received from a caller and the caller's socket.
          def drop(client, streams)
            [*streams, client].each do |io|
              release(io)
              io.close unless io.closed?
            end
          end
        end
      end
    end
  end
end
