require "json"
require "open3"
require "timeout"

require_relative "../../text"
require_relative "../agent"
require_relative "jev"

module Hecks
  module Adapters
    # Real `composer_agent` fulfillment for `draft` and `wire`: the developer's own `claude` run
    # as the `hecks-composer` agent, which edits the workspace's files in place. Transport only;
    # whether the edit is any good is the Composer's own check to judge.
    #
    # The agent's write guard confines it to domain files inside the git checkout, so the
    # workspace must sit inside one.
    module ClaudeComposer
      TIMEOUT_SECONDS = 300

      AGENT = "hecks-composer".freeze

      DRAFT = "Edit the domain files in %<dir>s as the request below says. Change only what it asks " \
              "for, write the bluebook first, then any hecksagon wiring it needs. Reply with one line " \
              "saying what you changed.".freeze

      WIRE = "Change how the bluebook in %<dir>s is wired, as the request below says: edit only its " \
             ".hecksagon and .world files, and bind adapters that already exist. Reply with one line " \
             "saying what you changed.".freeze

      module_function

      # @param prompt [String] what the author asked for
      # @param dir [String] the workspace directory
      # @return [Hash] `"note"` the agent's account of what it changed
      # @raise [Ports::Agent::Unavailable] see {Composer::Agent::Unavailable}
      def draft(prompt:, dir:) = call(DRAFT, prompt, dir)

      # @param prompt [String] what the author asked for
      # @param dir [String] the workspace directory
      # @return [Hash] `"note"` the agent's account of what it changed
      def wire(prompt:, dir:) = call(WIRE, prompt, dir)

      # Naming what a prompt asks for is the `jev` categorizer's work, which this adapter lends.
      #
      # @param prompt [String] what the author typed
      # @return [Hash] `"intent"` one of {Composer::Agent::INTENTS}
      # @raise [Composer::Agent::Unavailable] if `jev` cannot answer
      def classify(prompt:) = Jev.classify(prompt: prompt)

      # @api private
      def call(task, prompt, dir)
        root = checkout_of(dir)
        message = "#{format(task, dir: dir)}\n\nRequest: #{prompt}"
        stdout, status = run(root, message)
        raise Composer::Agent::Unavailable, "claude exited #{status.exitstatus}: #{stdout}" unless status.success?

        { "note" => Text.first_line(JSON.parse(stdout).fetch("result")) }
      rescue JSON::ParserError, KeyError => e
        raise Composer::Agent::ValidationError, "claude's reply was not the expected envelope: #{e.message}"
      end

      # Argv spawn, never a shell, so a `claude` shell alias cannot apply.
      # @api private
      def run(root, message)
        Timeout.timeout(TIMEOUT_SECONDS) do
          Open3.capture2("claude", "-p", "--agent", AGENT, "--output-format", "json",
                         "--permission-mode", "acceptEdits", stdin_data: message, chdir: root)
        end
      rescue Timeout::Error
        raise Composer::Agent::Unavailable, "claude did not answer within #{TIMEOUT_SECONDS}s"
      rescue Errno::ENOENT => e
        raise Composer::Agent::Unavailable, "claude is not on PATH: #{e.message}"
      end

      # @api private
      def checkout_of(dir)
        top, status = Open3.capture2("git", "-C", dir, "rev-parse", "--show-toplevel")
        raise Composer::Agent::Unavailable, "#{dir} is not inside a git checkout" unless status.success?

        top.strip
      end
    end
  end
end
