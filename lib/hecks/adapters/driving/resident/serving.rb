module Hecks
  module Adapters
    module Driving
      module Resident
        # How a resident takes one line: check who is calling, read the request and the caller's
        # three streams, check it can serve it, say `ready`, and fork a child that runs it only when
        # the caller answers `go`. The caller then waits for the child's exit status.
        #
        # The `go` is what keeps a line from running twice: a caller that gave up on a slow
        # resident has closed its socket, so a request that sat in the queue meets a closed
        # connection and is dropped, not run.
        module Serving
          # Seconds a caller has to send its request and streams before the resident drops it.
          REQUEST_WAIT = 3
          # Seconds a caller has to answer `ready` with `go`.
          CONFIRM_WAIT = 3

          private

          def handle(client)
            @active = Time.now
            streams = []
            return drop(client, streams) unless Peer.trusted?(client)

            request = Wire.read_request(client, seconds: REQUEST_WAIT)
            receive(client, streams)
            reason = unservable(request)
            reason ? refuse(client, streams, reason) : offer(client, request, streams)
          rescue StandardError, NoMemoryError
            drop(client, streams)
          end

          # Takes the caller's standard input, output and error, each within the wait.
          def receive(client, streams)
            3.times do
              client.wait_readable(REQUEST_WAIT) || raise(Wire::Slow, "the streams did not arrive")
              streams << client.recv_io
            end
          end

          # A line is served when it was made by this checkout's own launcher, with the environment
          # the code loaded under, and the code and declarations are as they were loaded; when they
          # changed, the resident retires.
          def servable?(request) = unservable(request).nil?

          # @return [String, nil] why the line cannot be served: `script` (not this checkout's
          #   launcher), `env` (an environment variable the code loaded under differs) or
          #   `changed` (the code or declarations changed, so the resident retires); nil when it can
          def unservable(request)
            return "script" unless same_script?(request)
            return "env" unless request[:env].slice(*loaded_names) == @environment
            return nil unless @fingerprint.changed?

            retire
            "changed"
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
          def offer(client, request, streams)
            Wire.reply(client, Wire::READY)
            confirmed?(client) ? launch(client, request, streams) : drop(client, streams)
          end

          def confirmed?(client)
            Wire.read_line(client, CONFIRM_WAIT) == Wire::GO
          rescue SystemCallError, IOError, Wire::Refused
            false
          end

          # Closes what was received from a caller and the caller's socket.
          def drop(client, streams)
            streams.each { |stream| stream.close unless stream.closed? }
            client.close unless client.closed?
          end

          def launch(client, request, streams)
            reader, writer = IO.pipe
            writer.sync = true
            pid = fork { become_child(client, request, streams, reader, writer) }
            writer.close
            streams.each(&:close)
            @monitors << Thread.new { monitor(pid, client, reader) }
          end

          def become_child(client, request, streams, reader, writer)
            [@server, @lock, client, reader].each(&:close)
            Worker.new(request, streams, @cache, writer).run
          end

          # Waits for the child, ends the caller's wait with its status, and stops the child if the
          # caller goes.
          def monitor(pid, client, reader)
            watcher = Thread.new { stop_when_gone(client, pid) }
            _, status = Process.wait2(pid)
            watcher.kill
            Wire.reply(client, "#{Wire::STATUS}#{status.exitstatus || (128 + status.termsig)}")
            remember(reader)
          rescue SystemCallError, IOError
            nil
          ensure
            client.close unless client.closed?
          end

          # Interrupts the child when the caller's end of the socket closes before the line is done.
          def stop_when_gone(client, pid)
            client.read(1)
            Process.kill("INT", pid)
          rescue SystemCallError, IOError
            nil
          end

          # Queues the domains and files a finished child named as missing from the resident.
          def remember(reader)
            text = reader.read_nonblock(65_536, exception: false)
            text.to_s.each_line { |line| @notes << line.chomp.split("\t", 3) }
          end
        end
      end
    end
  end
end
