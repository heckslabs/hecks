require "open3"
require "json"
require "net/http"
require "uri"
require_relative "base"

module Hecks
  class Runtime
    module LlmProviders

      # Hecks::Runtime::LlmProviders::ClaudeProvider
      #
      # Real-network provider for Anthropic's Claude. Two transport
      # paths, runtime-selected:
      #
      #   1. CLI (default, preferred) — `claude -p --output-format
      #      stream-json …` via Open3.popen3 with strict `unsetenv_others:
      #      true` and only HOME + PATH passed through. Uses Chris's
      #      Claude Max subscription auth (no API key required).
      #
      #   2. API (fallback) — POST https://api.anthropic.com/v1/messages
      #      via Net::HTTP, SSE stream parsing. Activated only when
      #      ENV["ANTHROPIC_API_KEY"] is set. The CLI is preferred
      #      because the user runs Claude Max ; do NOT reverse this.
      #
      # Boot probe runs `claude --version` (CLI mode) or returns true
      # (API mode — assume reachable, breaker handles 5xx). On probe
      # failure for CLI, the provider is marked degraded and #invoke
      # raises Hecks::LlmInvocationSkipped(reason: "provider_unavailable").
      #
      # Streaming: when `stream: true`, every text chunk is yielded to
      # the caller's block as it arrives ; the final accumulated Result
      # is also returned for spend accounting.
      #
      #   provider = ClaudeProvider.new
      #   provider.boot_probe          # => true | false
      #   result = provider.invoke(
      #     prompt: "hello",
      #     model: "claude-sonnet-4",
      #     max_tokens: 200
      #   )
      #   result.response_text         # => "hi back"
      #   result.tokens_in             # => 5
      #   result.tokens_out            # => 2
      #
      class ClaudeProvider
        API_URL    = "https://api.anthropic.com/v1/messages".freeze
        API_VERSION = "2023-06-01".freeze
        DEFAULT_BIN = "claude".freeze

        attr_reader :degraded_reason

        def initialize(cli_bin: DEFAULT_BIN, api_key: ENV["ANTHROPIC_API_KEY"])
          @cli_bin = cli_bin
          @api_key = api_key
          @degraded = false
          @degraded_reason = nil
        end

        # CLI is preferred when no API key is exported, even if
        # ANTHROPIC_API_KEY is set, the user can override by clearing it.
        # Mirrors plan §3 :claude.
        def transport
          @api_key && !@api_key.empty? ? :api : :cli
        end

        def degraded?
          @degraded
        end

        # Boot probe: lightweight reachability check. CLI runs
        # `claude --version` (cheap, doesn't burn a request). API path
        # has no equivalent ping, so we trust the breaker to gate.
        #
        # @return [Boolean] true = healthy, false = degraded
        def boot_probe
          if transport == :cli
            probe_cli
          else
            @degraded = false
            true
          end
        end

        # Invoke Claude. Raises LlmInvocationSkipped if the provider was
        # marked degraded by an earlier boot_probe failure.
        #
        # @param prompt [String]
        # @param model [String]
        # @param max_tokens [Integer]
        # @param stream [Boolean]
        # @yield [String] each streamed text chunk (only when stream:)
        # @return [Hecks::Runtime::LlmProviders::Result]
        # @raise [Hecks::LlmAdapterError] on transport failure
        # @raise [Hecks::LlmInvocationSkipped] when degraded
        def invoke(prompt:, model:, max_tokens:, stream: false, &block)
          if @degraded
            raise Hecks::LlmInvocationSkipped.new(reason: "provider_unavailable")
          end
          if transport == :cli
            invoke_cli(prompt, model, max_tokens, stream, &block)
          else
            invoke_api(prompt, model, max_tokens, stream, &block)
          end
        end

        private

        # CLI boot probe: `claude --version`. Failure marks degraded.
        def probe_cli
          env = cli_env
          _out, _err, status = Open3.capture3(
            env, @cli_bin, "--version",
            unsetenv_others: true,
            stdin_data: ""
          )
          ok = status.respond_to?(:success?) ? status.success? : status.to_i.zero?
          @degraded = !ok
          @degraded_reason = "claude --version exit #{status}" unless ok
          ok
        rescue Errno::ENOENT, Errno::EACCES => e
          @degraded = true
          @degraded_reason = e.message
          false
        end

        # CLI invocation: stream-json on stdout, parse JSON-per-line,
        # accumulate text from content_block_delta events, capture token
        # counts from message_stop / message_delta usage block.
        def invoke_cli(prompt, model, max_tokens, stream)
          args = ["-p",
                  "--output-format", "stream-json",
                  "--verbose",
                  "--model", model,
                  "--max-tokens", max_tokens.to_s]
          env = cli_env
          stdout_str, stderr_str, status = Open3.capture3(
            env, @cli_bin, *args,
            unsetenv_others: true,
            stdin_data: prompt
          )
          unless status.respond_to?(:success?) ? status.success? : status.to_i.zero?
            raise Hecks::LlmAdapterError,
                  "claude CLI exited #{status}: #{stderr_str.to_s.lines.first}"
          end
          parse_cli_stream(stdout_str, model, stream) { |chunk| yield chunk if block_given? }
        rescue Errno::ENOENT => e
          @degraded = true
          @degraded_reason = e.message
          raise Hecks::LlmAdapterError, "claude CLI not found: #{e.message}"
        end

        # Parse the `claude --output-format stream-json` payload :
        # one JSON object per line. Event shapes follow Anthropic's
        # streaming SDK : message_start (usage.input_tokens),
        # content_block_delta (delta.text), message_delta
        # (usage.output_tokens), message_stop (terminal sentinel).
        def parse_cli_stream(payload, model, stream_flag)
          text  = +""
          tin   = 0
          tout  = 0
          model_used = model
          raw_events = []
          payload.each_line do |line|
            line = line.strip
            next if line.empty?
            ev = (JSON.parse(line) rescue nil)
            next unless ev.is_a?(Hash)
            raw_events << ev
            tin, tout, model_used = absorb_event(ev, text, tin, tout, model_used, stream_flag) { |c| yield c }
          end
          Result.new(response_text: text, tokens_in: tin, tokens_out: tout,
                     model_used: model_used, raw: raw_events)
        end

        # Apply one stream-json event to the running accumulator.
        # Returns updated [tin, tout, model_used].
        def absorb_event(ev, text, tin, tout, model_used, stream_flag)
          case ev["type"]
          when "message_start"
            usage = ev.dig("message", "usage") || {}
            tin = usage["input_tokens"].to_i if usage["input_tokens"]
            mu = ev.dig("message", "model")
            model_used = mu if mu
          when "content_block_delta"
            chunk = ev.dig("delta", "text")
            if chunk
              text << chunk
              yield chunk if stream_flag
            end
          when "message_delta"
            usage = ev["usage"] || {}
            tout = usage["output_tokens"].to_i if usage["output_tokens"]
          when "message_stop"
            usage = ev["usage"] || ev.dig("message", "usage") || {}
            tin  = usage["input_tokens"].to_i  if usage["input_tokens"]
            tout = usage["output_tokens"].to_i if usage["output_tokens"]
          end
          [tin, tout, model_used]
        end

        # API path: POST /v1/messages. SSE stream parsed when stream
        # flag is set ; otherwise a single JSON response.
        def invoke_api(prompt, model, max_tokens, stream)
          uri = URI(API_URL)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          req = Net::HTTP::Post.new(uri)
          req["x-api-key"] = @api_key
          req["anthropic-version"] = API_VERSION
          req["content-type"] = "application/json"
          req["accept"] = stream ? "text/event-stream" : "application/json"
          req.body = JSON.generate(
            model: model, max_tokens: max_tokens,
            stream: stream,
            messages: [{ role: "user", content: prompt }]
          )
          if stream
            invoke_api_stream(http, req, model) { |c| yield c if block_given? }
          else
            invoke_api_unary(http, req, model)
          end
        end

        # API non-streaming branch.
        def invoke_api_unary(http, req, model)
          res = http.request(req)
          raise Hecks::LlmAdapterError, "claude API #{res.code}: #{res.body}" \
            unless res.code == "200"
          data = JSON.parse(res.body)
          text = (data["content"] || []).map { |b| b["text"] }.compact.join
          usage = data["usage"] || {}
          Result.new(
            response_text: text,
            tokens_in: usage["input_tokens"].to_i,
            tokens_out: usage["output_tokens"].to_i,
            model_used: data["model"] || model,
            raw: data
          )
        end

        # API streaming branch: read SSE from the open response.
        def invoke_api_stream(http, req, model)
          text  = +""
          tin   = 0
          tout  = 0
          model_used = model
          raw_events = []
          http.request(req) do |res|
            raise Hecks::LlmAdapterError, "claude API #{res.code}" \
              unless res.code == "200"
            buf = +""
            res.read_body do |chunk|
              buf << chunk
              while (i = buf.index("\n\n"))
                event = buf.slice!(0, i + 2)
                payload = event.lines.map { |l| l[/\Adata:\s*(.+)\z/, 1] }.compact.join
                next if payload.empty? || payload == "[DONE]"
                ev = (JSON.parse(payload) rescue nil)
                next unless ev.is_a?(Hash)
                raw_events << ev
                tin, tout, model_used = absorb_event(ev, text, tin, tout, model_used, true) { |c| yield c }
              end
            end
          end
          Result.new(response_text: text, tokens_in: tin, tokens_out: tout,
                     model_used: model_used, raw: raw_events)
        end

        # Strict env whitelist for the CLI subprocess. Mirrors the
        # shell_dispatcher discipline : unsetenv_others + only the
        # entries declared here flow through. The CLI legitimately
        # needs HOME (subscription auth state lives under
        # ~/.config/claude) and PATH (it shells out to find tools).
        def cli_env
          {
            "HOME" => ENV["HOME"].to_s,
            "PATH" => ENV["PATH"].to_s
          }
        end
      end

    end
  end
end
