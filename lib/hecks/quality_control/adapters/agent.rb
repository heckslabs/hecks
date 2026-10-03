# frozen_string_literal: true

require "open3"
require "shellwords"
require_relative "agent_profile"

module Hecks
  module Adapters
    # The `Agent` port's adapter: hands a prompt to an agent on the command line and lets it work
    # in the checkout, the way `hecks quality_control mine_combinations` asks one for candidate
    # domains.
    #
    # Not the interviewer behind the framework's `agent` port (`ClaudeCode`), which reads one
    # JSON answer back: this agent edits files, so the only answer is whether it finished.
    class Agent
      # An agent that could not start, or ended with a failure.
      class Failed < StandardError; end

      # The command run when neither the caller nor `QA_MINER_AGENT` names one.
      DEFAULT_COMMAND = ["claude", "-p", "--permission-mode", "acceptEdits",
                         "--allowedTools", "Read,Glob,Grep,Write,Edit"].freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # The command an ask runs.
      #
      # @param command [String, Array<String>, nil] a command line, or its words
      # @param profile [AgentProfile, nil] when given, the default command takes its tools, budget
      # @return [Array<String>] `command` as words; `QA_MINER_AGENT` else the default when nil
      def command_for(command = nil, profile = nil)
        command ||= ENV.fetch("QA_MINER_AGENT", nil)
        return default_command(profile) unless command

        command.is_a?(String) ? Shellwords.split(command) : command
      end

      # Runs the agent with `prompt` on its standard input.
      #
      # @param prompt [String] what the agent is asked to do
      # @param command [String, Array<String>, nil] the agent's command; see `command_for`
      # @param chdir [String] the directory the agent works in
      # @param log [String, nil] a file the agent's output is appended to
      # @param profile [AgentProfile, nil] what the run may do; nil runs it as the caller could
      # @return [String] the agent's output
      # @raise [Failed] when the agent cannot start, runs past its timeout or exits non-zero
      def ask(prompt:, chdir:, command: nil, log: nil, profile: nil)
        words = command_for(command, profile)
        refuse_unconfinable!(words, profile)
        output, status = run(words, prompt, chdir, profile)
        File.open(log, "a") { |file| file.puts(output) } if log
        return output if status.success?

        raise Failed, "agent exited #{status.exitstatus}: #{output.lines.last(5).join.strip}"
      rescue SystemCallError => e
        raise Failed, "agent could not start (#{words.first}): #{e.message}"
      end

      private

      # Permission rules are a feature of `claude`: any other command would run unconfined.
      def refuse_unconfinable!(words, profile)
        return if profile.nil? || profile.sandboxed? || words == default_command(profile)

        raise Failed, "permission confinement applies only to the default claude command"
      end

      def run(words, prompt, chdir, profile)
        return run_confined(words, prompt, chdir, profile) if profile

        Open3.capture2e(*words, stdin_data: prompt, chdir: chdir)
      end

      def default_command(profile)
        return DEFAULT_COMMAND unless profile

        %w[claude -p --permission-mode] + [profile.permission_mode] + profile.tool_flags
      end

      # Runs `words` under the profile's sandbox with only the environment it names, in its own
      # process group so a timeout takes the agent's children with it.
      def run_confined(words, prompt, chdir, profile)
        raise Failed, "no sandbox here; refusing to run an agent unconfined" unless profile.available?

        Open3.popen2e(profile.environment, *profile.confine(words),
                      chdir: chdir, unsetenv_others: true, pgroup: true) do |stdin, out, waiter|
          feed(stdin, prompt)
          reader = Thread.new { out.read }
          finish(waiter, reader, profile.timeout)
        end
      end

      def feed(stdin, prompt)
        stdin.write(prompt)
      rescue Errno::EPIPE
        nil
      ensure
        stdin.close
      end

      def finish(waiter, reader, timeout)
        unless waiter.join(timeout)
          Process.kill("KILL", -waiter.pid)
          waiter.join
          reader.join
          raise Failed, "agent timed out after #{timeout}s"
        end
        [reader.value, waiter.value]
      end
    end
  end
end
