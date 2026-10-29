# frozen_string_literal: true

require "open3"
require "rbconfig"
require "hecks/ci_speed/adapters/local_runner/refused"

module Hecks
  module Adapters
    class LocalRunner
      # Runs hecks verbs through `exe/hecks` of one checkout, as that checkout's own code would
      # run them. A step is only ever a verb call: nothing here takes a shell line.
      class Launcher
        # What every verb runs with: memory persistence, so a measured run writes no journal and
        # reaches no database, whatever this process was started with.
        ENVIRONMENT = { "HECKS_ENVIRONMENT" => "memory", "HECKS_DATABASE" => nil }.freeze

        # @param checkout [String] a checkout's path
        def initialize(checkout)
          @checkout = checkout
        end

        # @param step [Catalog::Step] the step to ask about
        # @return [Boolean] whether this checkout's launcher knows the step's verb, and every
        #   argument the step gives it
        def knows?(step)
          out, status = run(*step.form, "--help")
          status.success? && step.argument_names.all? { |name| out.include?("#{name}=") }
        end

        # Runs a step and times it.
        #
        # @param step [Catalog::Step] the step to run
        # @return [Float] the seconds it took, on a monotonic clock
        # @raise [Refused] with everything the verb printed, when it ends badly
        def time(step)
          words = [*step.form, *step.words, *("--wait" if step.verb.end_with?("!"))]
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          out, status = run(*words)
          seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          return seconds if status.success?

          raise Refused, "step #{step.name} (#{words.join(" ")}) ended with status #{status.exitstatus} " \
                         "in #{@checkout}:\n#{out}"
        end

        private

        # Runs the launcher as the leader of its own process group, so that when this process is
        # interrupted the verb and every process it forked go with it, and none is left running in
        # a checkout that is about to be removed.
        def run(*words)
          launch = [RbConfig.ruby, File.join(@checkout, "exe", "hecks"), *words]
          Open3.popen2e(ENVIRONMENT, *launch, chdir: @checkout, pgroup: true) do |input, output, waiter|
            input.close
            [output.read, waiter.value]
          ensure
            stop(waiter.pid) if waiter.alive?
          end
        end

        def stop(group)
          Process.kill("TERM", -group)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end
  end
end
