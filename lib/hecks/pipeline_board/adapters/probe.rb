# frozen_string_literal: true

require "json"
require_relative "probe/child"

module Hecks
  module Adapters
    # What the PipelineBoard readers share: the reason a read failed, the outside command they run,
    # and the short cache that keeps a polling page from hammering it.
    module PipelineBoard
      # A read that could not be answered. The message is the reason a stage shows after `unknown:`.
      class Unavailable < StandardError; end

      # Runs one outside command for a reader and answers its standard output. The command never
      # outlives the read (see {Child}), and its bound is under the {Gather} bound, so a read that
      # is given up on has already stopped its child.
      module Probe
        TIMEOUT_SECONDS = 15
        # The variable a launcher line reads its caller from, and the name the board gives, so the
        # usage log shows the launcher lines this server runs.
        CALLER_VARIABLE = "HECKS_CALLER"
        CALLER = "board"

        # @param command [Array<String>] the program and its arguments, never a shell string
        # @param chdir [String, nil] where it runs
        # @param stdin [String, nil] what is written to its standard input, then closed
        # @return [String] standard output
        # @raise [Unavailable] when the program is missing, times out (it is stopped first) or
        #   exits non-zero
        def self.run(*command, chdir: nil, seconds: TIMEOUT_SECONDS, stdin: nil)
          child = Child.new(command, environment: { CALLER_VARIABLE => CALLER }, chdir: chdir || Dir.pwd, seconds: seconds)
          out, err, status = child.call(stdin.to_s)
          raise Unavailable, "#{command.first} #{command[1]}: #{reason(err)}" unless status.success?

          out
        rescue Errno::ENOENT then raise Unavailable, "#{command.first} is not installed"
        rescue Child::Overdue then raise Unavailable, "#{command.first} did not answer in #{seconds}s"
        end

        # The launcher's notices (boot warnings and the worktree's missing local files) come before
        # the refusal, so the reason is the first line that is not one of them.
        NOTICE = /\A(\[hecks\]|hecks: this worktree lacks|.*: warning: )/

        # @return [String] the first line the command wrote to standard error that is not a notice
        def self.reason(err)
          lines = err.lines.map(&:strip).reject(&:empty?)
          (lines.find { |line| !NOTICE.match?(line) } || lines.first).to_s
        end

        # @return [Object] the JSON the command printed
        # @raise [Unavailable] when the output is not JSON
        def self.json(*command, chdir: nil)
          JSON.parse(run(*command, chdir: chdir))
        rescue JSON::ParserError => e
          raise Unavailable, "#{command.first} printed no JSON: #{e.message[0, 60]}"
        end
      end
    end
  end
end
