# Hecks::Extensions::ClaudeCliAdapter
#
# LLM adapter that routes through the local `claude` CLI. Uses the
# user's existing Claude subscription (Max, Pro, etc.) instead of
# API credits. Shells out to `claude -p` with system prompt and
# JSON output parsing.
#
#   adapter = ClaudeCliAdapter.new(model: "sonnet")
#   response = adapter.chat(messages: [...], tools: [...], system: "You are...")
#   response[:content]  # => "The Pizzas domain has two aggregates..."
#
require "json"
require "open3"

module Hecks
  module Extensions
    class ClaudeCliAdapter
      def initialize(model: "sonnet", max_tokens: 4096)
        @model = model
        @max_tokens = max_tokens
      end

      # Send a chat request through the claude CLI.
      #
      # Tools are included as context in the system prompt since the CLI
      # doesn't accept tool definitions directly. The CLI handles tool
      # use internally when available.
      #
      # @param messages [Array<Hash>] conversation messages
      # @param tools [Array<Hash>] tool definitions (appended to system prompt)
      # @param system [String] system prompt
      # @return [Hash] normalized response { role:, content:, tool_calls: [] }
      def chat(messages:, tools:, system:)
        full_system = build_system_prompt(system, tools)
        prompt = build_prompt(messages)

        output = run_cli(prompt, full_system)
        parse_response(output)
      end

      private

      def run_cli(prompt, system_prompt)
        require "tempfile"
        file = Tempfile.new(["hecks_system_prompt", ".txt"])
        file.write(system_prompt)
        file.close

        cmd = [
          "claude", "-p",
          "--model", @model,
          "--output-format", "json",
          "--system-prompt-file", file.path,
          "--max-turns", "3",
          "--disallowedTools", "Bash,Write,Edit,Agent,Glob,Grep,Read,WebSearch,WebFetch,NotebookEdit"
        ]

        stdout, stderr, status = Open3.capture3(*cmd, stdin_data: prompt)

        # CLI returns exit 1 for max_turns but may still have a result
        if !status.success? && !stdout.include?('"result"')
          detail = stderr.strip.empty? ? stdout.strip : stderr.strip
          raise "Claude CLI error (exit #{status.exitstatus}): #{detail}"
        end

        stdout
      ensure
        file&.unlink
      end

      def build_system_prompt(system, tools)
        parts = [system]

        unless tools.empty?
          tool_desc = tools.map { |t|
            params = (t[:parameters] || []).map { |p| "#{p[:name]} (#{p[:type]})" }.join(", ")
            "- #{t[:name]}(#{params}): #{t[:description]}"
          }.join("\n")
          parts << "Available domain commands:\n#{tool_desc}"
        end

        parts << "IMPORTANT: Respond with text only. Do not use any tools. Do not read files or run commands. Answer based solely on the domain information provided above."
        parts.join("\n\n")
      end

      def build_prompt(messages)
        messages.select { |m|
          role = m[:role] || m["role"]
          role == "user" || role == "assistant"
        }.map { |m|
          role = m[:role] || m["role"]
          content = m[:content] || m["content"]
          "#{role}: #{content}"
        }.join("\n\n")
      end

      def parse_response(output)
        data = JSON.parse(output)
        content = extract_content(data)
        { role: "assistant", content: content, tool_calls: [] }
      rescue JSON::ParserError
        { role: "assistant", content: output.strip, tool_calls: [] }
      end

      def extract_content(data)
        if data.is_a?(Hash) && data["result"]
          data["result"]
        elsif data.is_a?(Hash) && data["content"]
          data["content"]
        elsif data.is_a?(String)
          data
        else
          data.to_s
        end
      end
    end
  end
end
