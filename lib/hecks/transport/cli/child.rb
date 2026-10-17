# frozen_string_literal: true

module Hecks
  module Transport
    module Cli
      # One running program and everything it starts, held as a process group.
      #
      # A timeout, an interrupt or any other raise while waiting stops the whole group: `TERM`
      # first, because a well-behaved program settles its own cleanup, then `KILL` regardless,
      # because a leader that exits cleanly on `TERM` can leave its children running, and the
      # group outlives its leader while any member does.
      class Child
        # How long a stopped group has to exit on `TERM` before it is killed.
        GRACE_SECONDS = 2

        # How often a run with a timeout checks whether its program has ended.
        POLL_SECONDS = 0.05

        # Starts a program in its own process group and waits for it.
        #
        # @param command [Array<String>] the program, then its arguments; never given to a shell
        # @param files [Hash{Symbol => String}] `out:` and `err:`, the files its output goes to
        # @param env [Hash{String => String, nil}] variables to set for it; nil unsets one
        # @param chdir [String, nil] the directory to run it in, or nil for the current one
        # @param timeout [Numeric, nil] seconds before its group is stopped; nil waits as long as
        #   it runs
        # @return [Process::Status] how the program ended
        # @raise [Cli::NotInstalled] if the program cannot be found
        # @raise [Cli::TimedOut] if it runs past `timeout`
        def self.run(command, files:, env:, chdir:, timeout:)
          options = { out: files.fetch(:out), err: files.fetch(:err), in: File::NULL, pgroup: true }
          options[:chdir] = chdir if chdir
          new(Process.spawn(env, *command, **options), command.first, timeout).wait
        rescue Errno::ENOENT => e
          raise NotInstalled, "#{command.first} is not installed: #{e.message}"
        end

        # @param pid [Integer] the program's process id, which is also its group's id
        # @param program [String] the program's name, worded into a timeout
        # @param timeout [Numeric, nil] seconds before the group is stopped, or nil for none
        def initialize(pid, program, timeout)
          @pid = pid
          @program = program
          @timeout = timeout
        end

        # Waits for the program to end, stopping its group if it does not end in time.
        #
        # @return [Process::Status] how the program ended
        # @raise [Cli::TimedOut] if it runs past the timeout
        def wait
          status = @timeout ? poll : Process.wait2(@pid).last
          raise TimedOut, "#{@program} did not finish within #{@timeout}s; its process group was stopped" unless status

          status
        ensure
          stop unless status
        end

        private

        def poll
          deadline = now + @timeout
          loop do
            status = reaped
            return status if status
            return nil if now >= deadline

            sleep POLL_SECONDS
          end
        end

        def stop
          signal("TERM")
          gone = reaped_within?(GRACE_SECONDS)
          signal("KILL")
          Process.wait2(@pid) unless gone
        rescue Errno::ECHILD
          nil
        end

        def reaped_within?(seconds)
          deadline = now + seconds
          until now >= deadline
            return true if reaped

            sleep POLL_SECONDS
          end
          false
        end

        def reaped = Process.wait2(@pid, Process::WNOHANG)&.last

        def signal(name)
          Process.kill(name, -@pid)
        rescue Errno::ESRCH
          nil
        end

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
