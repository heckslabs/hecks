# frozen_string_literal: true

require_relative "console_capture"
require "hecks/cli/console"

module Hecks
  module Adapters
    # The `Terminal` port's adapter: the sessions an operator or a program drives through stdin and
    # stdout, an IRB console (`open`) or the stdio MCP door (`serve`).
    #
    # The journal records that a session was opened and how it ended, not what was said in it.
    # Each starts here and nowhere else; a caller that must not open a real session (a spec)
    # replaces the launcher with `Terminal.launcher=` or the server with `Terminal.server=`.
    class Terminal
      class << self
        # @return [#call, nil] starts the interactive session; IRB when nil
        attr_accessor :launcher

        # @return [#call, nil] serves MCP over stdio, given the arguments after the command;
        #   `Hecks::CLI::Mcp.call` when nil
        attr_accessor :server
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Boots the record's domain and drops into an interactive console; returns when the
      # session ends.
      #
      # @param held [Hash] the `Operation` record: `subject` is the domain directory, or absent
      #   for the bundled pizzas domain
      # @return [Hash{Symbol => Hash}] `output:` a one-line note that the session ended
      def open(**held)
        subject = held[:subject]
        domain  = subject.is_a?(Hash) ? subject[:value] : subject
        launcher = self.class.launcher
        launcher ? CLI::Console.call(domain, launcher: launcher) : CLI::Console.call(domain)

        { output: { value: "console session ended (#{domain || 'pizzas'})" } }
      end

      # Hands the process over to the MCP door until the client closes stdin. The door writes its
      # JSON-RPC on stdout, so nothing here is captured, and the launcher's own answer follows
      # only once the client is gone.
      #
      # @param held [Hash] the `Door` record: `stdio` (whether `--stdio` was given)
      # @return [Hash{Symbol => Hash}] `output:` a one-line note that the door closed
      # @raise [ConsoleCapture::Failure] when the process is not set up for stdio: the door
      #   refused to start, and said why on stderr
      def serve(**held)
        argv = plain(held[:stdio]) ? ["--stdio"] : []
        server = self.class.server
        if server
          server.call(argv)
        else
          require "hecks/cli/mcp"
          CLI::Mcp.call(argv)
        end

        { output: { value: "mcp door closed" } }
      rescue SystemExit => e
        raise ConsoleCapture::Failure, "the mcp door refused to start (status #{e.status}); see stderr"
      end

      # Holds an interview at the terminal and writes the domain it drafts (ADR 0088). Asking is IO,
      # so it happens here and nowhere else; the journal records that one was held, not its words.
      #
      # @param held [Hash] the `Door` record: `name`; optionally `adapter`, `dir`, `expert`, `no_ai`
      # @return [Hash{Symbol => Hash}] `output:` what the interview wrote, or that it wrote nothing
      # @raise [ConsoleCapture::Failure] when the name or adapter is refused, or a file is there
      def converse(**held)
        require "hecks/cli/interview_run"
        report = CLI::InterviewRun.call(name: plain(held[:name]), adapter: plain(held[:adapter]), dir: plain(held[:dir]),
                                        expert: plain(held[:expert]), use_ai: !plain(held[:no_ai]))
        { output: { value: report.empty? ? "no interview was written" : report } }
      rescue ArgumentError => e
        raise ConsoleCapture::Failure, e.message
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
