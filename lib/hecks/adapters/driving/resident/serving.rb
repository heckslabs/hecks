module Hecks
  module Adapters
    module Driving
      module Resident
        # How a resident takes one line: read the request and the caller's three streams, check
        # it can serve it, fork a child that runs it, and answer the caller with the child's
        # exit status.
        module Serving
          # Seconds a caller has to send its request before the resident drops it.
          REQUEST_WAIT = 3

          private

          def handle(client)
            @active = Time.now
            return client.close unless client.wait_readable(REQUEST_WAIT)

            request = Wire.read_request(client)
            streams = Array.new(3) { client.recv_io }
            servable?(request) ? launch(client, request, streams) : refuse(client)
          rescue StandardError
            client.close unless client.closed?
          end

          # A line is served when it was made with the environment the code loaded under and the
          # code and declarations are as they were loaded; when they changed, the resident retires.
          def servable?(request)
            return false unless request[:env].slice(*Loading::LOADED_WITH) == @environment
            return true if @fingerprint.current == @baseline

            retire
            false
          end

          def refuse(client)
            Wire.reply(client, Wire::STALE)
            client.close
          end

          def launch(client, request, streams)
            Wire.reply(client, Wire::GO)
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
