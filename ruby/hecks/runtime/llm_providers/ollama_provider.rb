require "net/http"
require "uri"
require "json"
require_relative "base"

module Hecks
  class Runtime
    module LlmProviders

      # Hecks::Runtime::LlmProviders::OllamaProvider
      #
      # HTTP-only provider for a local (or remote) Ollama daemon. Talks
      # to the daemon's REST API at config.url, defaulting to
      # http://localhost:11434.
      #
      # Endpoints used :
      #   GET  /api/tags     — boot probe (lists pulled models)
      #   POST /api/generate — invocation, supports streaming via
      #                        chunked NDJSON (one JSON object per line)
      #
      # Boot probe: GET /api/tags ; on connection refused or non-200 the
      # provider is marked degraded and #invoke raises
      # Hecks::LlmInvocationSkipped(reason: "provider_unavailable").
      #
      # Streaming: when `stream: true`, every `response` field arriving
      # in the NDJSON body is yielded to the caller's block. Final token
      # counts come from the closing object's `prompt_eval_count` /
      # `eval_count` fields.
      #
      #   provider = OllamaProvider.new(url: "http://localhost:11434")
      #   provider.boot_probe                # => true | false
      #   result = provider.invoke(
      #     prompt: "hello",
      #     model: "llama3",
      #     max_tokens: 200
      #   )
      #   result.response_text               # => "hi back"
      #   result.tokens_in                   # => 5
      #   result.tokens_out                  # => 2
      #
      class OllamaProvider
        DEFAULT_URL = "http://localhost:11434".freeze

        attr_reader :degraded_reason, :url

        def initialize(url: DEFAULT_URL)
          @url = url || DEFAULT_URL
          @degraded = false
          @degraded_reason = nil
        end

        def degraded?
          @degraded
        end

        # Boot probe : GET /api/tags. Marks degraded on any connection
        # failure or non-2xx response.
        #
        # @return [Boolean] true = healthy, false = degraded
        def boot_probe
          uri = URI.join(@url, "/api/tags")
          res = http_for(uri).request(Net::HTTP::Get.new(uri))
          ok = res.code.to_i.between?(200, 299)
          @degraded = !ok
          @degraded_reason = "ollama /api/tags #{res.code}" unless ok
          ok
        rescue StandardError => e
          @degraded = true
          @degraded_reason = e.message
          false
        end

        # Invoke Ollama. Raises LlmInvocationSkipped if the provider was
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
          uri  = URI.join(@url, "/api/generate")
          req  = build_request(uri, prompt, model, max_tokens, stream)
          http = http_for(uri)
          if stream
            invoke_stream(http, req, model, &block)
          else
            invoke_unary(http, req, model)
          end
        rescue Hecks::LlmAdapterError, Hecks::LlmInvocationSkipped
          raise
        rescue StandardError => e
          raise Hecks::LlmAdapterError, "ollama transport error: #{e.message}"
        end

        private

        def build_request(uri, prompt, model, max_tokens, stream)
          req = Net::HTTP::Post.new(uri)
          req["content-type"] = "application/json"
          req.body = JSON.generate(
            model: model,
            prompt: prompt,
            stream: stream,
            options: { num_predict: max_tokens }
          )
          req
        end

        def http_for(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http
        end

        # Single-shot JSON response (stream=false). Ollama collapses
        # the whole reply into one object with a `response` field.
        def invoke_unary(http, req, model)
          res = http.request(req)
          raise Hecks::LlmAdapterError, "ollama #{res.code}: #{res.body}" \
            unless res.code == "200"
          data = JSON.parse(res.body)
          Result.new(
            response_text: data["response"].to_s,
            tokens_in:  data["prompt_eval_count"].to_i,
            tokens_out: data["eval_count"].to_i,
            model_used: data["model"] || model,
            raw: data
          )
        end

        # Streaming branch : NDJSON over chunked transfer. Each chunk
        # holds one or more JSON objects separated by newlines ; the
        # last one (with `done: true`) carries the token counts.
        def invoke_stream(http, req, model)
          text  = +""
          tin   = 0
          tout  = 0
          model_used = model
          raw_events = []
          http.request(req) do |res|
            raise Hecks::LlmAdapterError, "ollama #{res.code}" \
              unless res.code == "200"
            buf = +""
            res.read_body do |chunk|
              buf << chunk
              while (idx = buf.index("\n"))
                line = buf.slice!(0, idx + 1).strip
                next if line.empty?
                ev = (JSON.parse(line) rescue nil)
                next unless ev.is_a?(Hash)
                raw_events << ev
                tin, tout, model_used = absorb(ev, text, tin, tout, model_used) { |c| yield c if block_given? }
              end
            end
          end
          Result.new(response_text: text, tokens_in: tin, tokens_out: tout,
                     model_used: model_used, raw: raw_events)
        end

        # Apply one NDJSON line to the running accumulator.
        # Yields the new `response` chunk if the caller is streaming.
        def absorb(ev, text, tin, tout, model_used)
          if (chunk = ev["response"]) && !chunk.empty?
            text << chunk
            yield chunk
          end
          model_used = ev["model"] if ev["model"]
          if ev["done"]
            tin  = ev["prompt_eval_count"].to_i if ev["prompt_eval_count"]
            tout = ev["eval_count"].to_i        if ev["eval_count"]
          end
          [tin, tout, model_used]
        end
      end

    end
  end
end
