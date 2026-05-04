require "digest"

module Hecks
  class Runtime
    module LlmProviders

      # Hecks::Runtime::LlmProviders::TestProvider
      #
      # Fixture-backed in-memory LLM provider. Every prompt is hashed
      # (SHA-256) and looked up in a pre-loaded fixture table. Used by
      # specs and by CI runs of consumer code that would otherwise call
      # Claude / Ollama.
      #
      # Two miss modes are supported:
      #   - lenient (default): unknown prompt hashes return a synthetic
      #     placeholder response so downstream code can still exercise
      #     its pipeline. Useful while developing a new caller before
      #     fixtures are captured.
      #   - strict (env HECKS_LLM_FIXTURE_STRICT=1): unknown hashes
      #     raise Hecks::LlmInvocationFailed(reason: "fixture_missing").
      #     Used by CI so a missing fixture fails fast.
      #
      # Capture/replay seam:
      #   HECKS_LLM_REPLAY=path  — load fixtures from a YAML file at
      #                            construction (one entry per
      #                            prompt_sha256). Step 4 only wires
      #                            the seam ; the file format is owned
      #                            by a follow-up step.
      #   HECKS_LLM_CAPTURE=path — placeholder ; this step does not yet
      #                            capture, but consumers can detect
      #                            the env to know capture mode is
      #                            requested.
      #
      #   provider = TestProvider.new(
      #     fixtures: { Digest::SHA256.hexdigest("hi") => "hello back" }
      #   )
      #   r = provider.invoke(prompt: "hi", model: "x", max_tokens: 10)
      #   r.response_text   # => "hello back"
      #   r.tokens_in       # => 1   (whitespace-token estimate)
      #   r.tokens_out      # => 2
      #
      class TestProvider
        # Default placeholder text returned in lenient mode for an
        # unknown prompt hash. The hash is included so debugging /
        # capture is easy : grep for the hash in fixtures.
        UNKNOWN_PROMPT_TEMPLATE = "[test-provider:unknown-prompt sha256=%s]".freeze

        # @return [Symbol] provider name (:test)
        def name
          :test
        end

        # @param fixtures [Hash{String=>String}] prompt_sha256 -> response_text
        # @param strict [Boolean, nil] override env-driven strict mode (nil = follow env)
        # @param capture_path [String, nil] from HECKS_LLM_CAPTURE (seam only)
        def initialize(fixtures: {}, strict: nil, capture_path: nil, env: ENV)
          @fixtures = stringify_fixture_keys(fixtures)
          @strict = strict.nil? ? env["HECKS_LLM_FIXTURE_STRICT"] == "1" : !!strict
          @capture_path = capture_path || env["HECKS_LLM_CAPTURE"]
        end

        # Number of fixtures registered (for diagnostics).
        # @return [Integer]
        def fixture_count
          @fixtures.size
        end

        # @return [Boolean] true if HECKS_LLM_FIXTURE_STRICT=1 (or strict: true was passed)
        def strict?
          @strict
        end

        # @return [String, nil] capture target path (seam ; not yet written)
        attr_reader :capture_path

        # SHA-256 of a prompt — exposed so callers / specs can register
        # fixtures without re-deriving the digest.
        #
        # @param prompt [String]
        # @return [String] hex digest
        def self.hash_for(prompt)
          Digest::SHA256.hexdigest(prompt.to_s)
        end

        # Look up a fixture by prompt and return a LlmProviders::Result.
        #
        # @param prompt [String] the fully-substituted prompt
        # @param model [String, nil] adapter's model (echoed in result)
        # @param max_tokens [Integer, nil] adapter's budget (advisory only here)
        # @param stream [Boolean] streaming flag (TestProvider ignores ; non-streaming)
        # @return [Hecks::Runtime::LlmProviders::Result]
        # @raise [Hecks::LlmInvocationFailed] when strict mode and no fixture
        def invoke(prompt:, model: nil, max_tokens: nil, stream: false)
          digest = self.class.hash_for(prompt)
          response_text =
            if @fixtures.key?(digest)
              @fixtures[digest]
            elsif @strict
              raise Hecks::LlmInvocationFailed.new(
                "test provider: no fixture for prompt sha256=#{digest}",
                provider: :test, reason: "fixture_missing"
              )
            else
              format(UNKNOWN_PROMPT_TEMPLATE, digest)
            end

          Result.new(
            response_text: response_text,
            tokens_in: estimate_tokens(prompt),
            tokens_out: estimate_tokens(response_text),
            model_used: model,
            raw: { provider: :test, digest: digest, max_tokens: max_tokens, stream: stream }
          )
        end

        private

        # Whitespace-split token estimate. Real providers report exact
        # counts ; the test provider returns a stable approximation so
        # spend-accounting code paths can be exercised in fixtures.
        #
        # @param text [String]
        # @return [Integer]
        def estimate_tokens(text)
          text.to_s.split(/\s+/).reject(&:empty?).length
        end

        # Accept either string or symbol keys for fixture maps.
        # SHA-256 hex digests are always strings, but symbol-keyed
        # fixture hashes show up in Ruby specs naturally — normalize.
        def stringify_fixture_keys(fixtures)
          h = {}
          fixtures.each { |k, v| h[k.to_s] = v.to_s }
          h
        end
      end
    end
  end
end
