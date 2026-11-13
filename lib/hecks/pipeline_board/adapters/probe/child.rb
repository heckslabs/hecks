# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    module PipelineBoard
      module Probe
        # One outside command a reader runs, in its own process group, that never outlives the read:
        # past its bound, or when the reading thread is killed, the group is asked to stop, then
        # killed after a grace, and reaped, so a slow read on a loaded machine leaves no child.
        class Child
          # The command ran past its bound and was stopped.
          class Overdue < StandardError; end

          # Seconds a group asked to stop is given before it is killed, and the output readers to
          # finish once it has exited.
          GRACE_SECONDS = 1

          # @param command [Array<String>] the program and its arguments, never a shell string
          # @param environment [Hash{String => String}] added to the child's environment
          # @param chdir [String] where it runs
          # @param seconds [Numeric] how long it may run
          def initialize(command, environment:, chdir:, seconds:)
            @command = command
            @environment = environment
            @chdir = chdir
            @seconds = seconds
          end

          # @param input [String] written to the child's standard input, which is then closed
          # @return [Array(String, String, Process::Status)] standard output, standard error and
          #   how it exited
          # @raise [Overdue] when it runs past its bound; it is stopped and reaped first
          # @raise [Errno::ENOENT] when the program is missing
          def call(input)
            Open3.popen3(@environment, *@command, chdir: @chdir, pgroup: true) do |stdin, out, err, waiter|
              readers = [out, err].map { |io| reader(io) }
              feed(stdin, input)
              collected(waiter, readers)
            ensure
              stop(waiter, readers)
            end
          end

          private

          def collected(waiter, readers)
            raise Overdue unless waiter.join(@seconds)

            [*readers.map(&:value), waiter.value]
          end

          def reader(io)
            Thread.new { io.read }.tap { |thread| thread.report_on_exception = false }
          end

          def feed(stdin, input)
            stdin.write(input) unless input.empty?
          rescue Errno::EPIPE
            nil
          ensure
            stdin.close
          end

          # Stops the group when it is still running and lets the readers drain, so neither the
          # child nor a reader thread is left behind.
          def stop(waiter, readers)
            return unless waiter

            signal("TERM", waiter.pid) if waiter.alive?
            signal("KILL", waiter.pid) unless waiter.join(GRACE_SECONDS)
            waiter.join
            Array(readers).each { |thread| thread.join(GRACE_SECONDS) || thread.kill }
          end

          def signal(name, pid)
            Process.kill(name, -pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
      end
    end
  end
end
