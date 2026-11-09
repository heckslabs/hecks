module Hecks
  module Adapters
    module Driving
      module Resident
        # How a resident runs a line once its caller has said `go`: it forks a child that runs the
        # line, watches the child until it ends, and tells the caller the child's status. Forks take
        # turns, so that none copies the resident while another is part way through, or while it
        # loads what children found missing; every other part of a line runs at once with the rest.
        module Forking
          private

          def launch(client, request, streams)
            @active = Time.now
            reader, writer = IO.pipe
            writer.sync = true
            pid = @fork_lock.synchronize { fork_child(client, request, streams, [reader, writer]) }
            writer.close
            close_streams(streams)
            watch = Thread.new { monitor(pid, client, reader) }
            @guard.synchronize { @monitors << watch }
          end

          # Lets go of the streams the caller sent, which the child now holds.
          def close_streams(streams)
            streams.each do |stream|
              release(stream)
              stream.close
            end
          end

          # @return [Integer] the child's process id
          def fork_child(client, request, streams, pipe)
            others = @guard.synchronize { @held - streams - [client] }
            pid = fork { become_child(client, request, streams, pipe, others) }
            into_group(pid, pid)
            pid
          end

          # The child leads a process group of its own, which the resident also sets from its side
          # so the group stands whichever of them runs first, and the child's own processes (a
          # build, a gate) can be stopped with it. It closes every other caller's socket and
          # streams it inherited, so that none is held open for as long as this line runs.
          def become_child(client, request, streams, pipe, others)
            reader, writer = pipe
            into_group(0, 0)
            [@server, @lock, client, reader, *others].each { |io| io.close unless io.closed? }
            Worker.new(request, streams, @cache, writer).run
          end

          # Waits for the child, ends the caller's wait with its status, and stops the child if the
          # caller goes.
          def monitor(pid, client, reader)
            watcher = Thread.new { stop_when_gone(client, pid) }
            _, status = Process.wait2(pid)
            watcher.kill
            finish_line(client, status)
            remember(reader)
          rescue SystemCallError, IOError
            nil
          ensure
            release(client)
            client.close unless client.closed?
          end

          # Marks the end of a line as use, so the resident is not idle the moment a long line ends,
          # and tells the caller the line's status.
          def finish_line(client, status)
            @active = Time.now
            Wire.reply(client, "#{Wire::STATUS}#{status.exitstatus || (128 + status.termsig)}")
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
