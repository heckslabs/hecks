# frozen_string_literal: true

require "open3"
require "shellwords"

module Hecks
  module Adapters
    # The `Agent` port's adapter: hands a prompt to an agent on the command line and lets it work
    # in the checkout, the way `hecks quality_control target.mine_combinations` asks one for
    # candidate domains.
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
      # @return [Array<String>] `command` as words; `QA_MINER_AGENT` else `DEFAULT_COMMAND` when nil
      def command_for(command = nil)
        command ||= ENV.fetch("QA_MINER_AGENT", nil)
        return DEFAULT_COMMAND unless command

        command.is_a?(String) ? Shellwords.split(command) : command
      end

      # Runs the agent with `prompt` on its standard input.
      #
      # @param prompt [String] what the agent is asked to do
      # @param command [String, Array<String>, nil] the agent's command; see `command_for`
      # @param chdir [String] the directory the agent works in
      # @param log [String, nil] a file the agent's output is appended to
      # @return [String] the agent's output
      # @raise [Failed] when the agent cannot start or exits non-zero
      def ask(prompt:, chdir:, command: nil, log: nil)
        words = command_for(command)
        output, status = Open3.capture2e(*words, stdin_data: prompt, chdir: chdir)
        File.open(log, "a") { |file| file.puts(output) } if log
        return output if status.success?

        raise Failed, "agent exited #{status.exitstatus}: #{output.lines.last(5).join.strip}"
      rescue SystemCallError => e
        raise Failed, "agent could not start (#{words.first}): #{e.message}"
      end
    end
  end
end
