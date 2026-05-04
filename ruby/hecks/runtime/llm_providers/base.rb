# Hecks::Runtime::LlmProviders — namespace + sibling stubs
#
# Phase 2 step 5 (this file) defines:
#   - The shared Result struct returned by every provider's #invoke
#   - The Hecks::LlmAdapterError raised on transport failure
#   - The LlmInvocationSkipped error raised when a provider is degraded
#     (boot probe failed) so the dispatcher can surface it as a skip
#     rather than a hard failure
#
# These three definitions are owned by step 4 (LlmDispatcher +
# TestProvider). Step 4's branch had not pushed when this provider step
# was authored, so the trio is stubbed here behind `defined?` guards —
# when step 4 lands and merges, the stubs are dropped at merge and step
# 4's canonical definitions take over. The contract locked here is:
#
#   Result = Struct.new(
#     :response_text, :tokens_in, :tokens_out, :model_used, :raw,
#     keyword_init: true
#   )
#
#   class Hecks::LlmAdapterError < StandardError; end
#   class Hecks::LlmInvocationSkipped < Hecks::LlmAdapterError
#     attr_reader :reason
#     def initialize(message = nil, reason: nil) ... end
#   end
#
# The provider#invoke signature is:
#
#   invoke(prompt:, model:, max_tokens:, stream: false) -> Result
#
# Stream mode yields chunks from a block argument when given; the
# accumulated final Result is also returned.
#
module Hecks
  unless defined?(Hecks::LlmAdapterError)
    # Raised by a provider on transport failure (HTTP 5xx, subprocess
    # crash, malformed payload). Catchable separately from
    # ::StandardError so callers can decide policy (open breaker vs
    # propagate).
    class LlmAdapterError < StandardError; end
  end

  unless defined?(Hecks::LlmInvocationSkipped)
    # Raised when a provider declines to invoke (degraded boot probe,
    # breaker open, budget exceeded). Carries a machine-readable
    # `reason` so the dispatcher can branch without parsing strings.
    class LlmInvocationSkipped < Hecks::LlmAdapterError
      attr_reader :reason
      def initialize(message = nil, reason: nil)
        @reason = reason
        super(message || "llm invocation skipped: #{reason}")
      end
    end
  end

  class Runtime
    # Hecks::Runtime::LlmProviders
    #
    # Namespace for every concrete LLM backend (Claude, Ollama, OpenAI,
    # test) that the LlmDispatcher can route through. Each provider
    # exposes:
    #
    #   invoke(prompt:, model:, max_tokens:, stream: false) -> Result
    #   boot_probe -> Boolean   # true = healthy, false = degraded
    #   degraded?               -> Boolean (cached state from last probe)
    #
    # Result fields:
    #
    #   response_text [String]   accumulated text returned by the model
    #   tokens_in     [Integer]  input tokens reported by the backend
    #   tokens_out    [Integer]  output tokens reported by the backend
    #   model_used    [String]   the model id the backend actually ran
    #   raw           [Object]   the raw payload (Hash or Array) for
    #                            forensics / Spend.RecordCall context
    #
    module LlmProviders
      unless defined?(Hecks::Runtime::LlmProviders::Result)
        Result = Struct.new(
          :response_text, :tokens_in, :tokens_out, :model_used, :raw,
          keyword_init: true
        )
      end
    end
  end
end
