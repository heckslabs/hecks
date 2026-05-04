module Hecks
  class Runtime

    # Hecks::Runtime::LlmProviders
    #
    # Namespace for LLM provider adapters used by LlmDispatcher. Every
    # provider in this module exposes a single seam:
    #
    #   provider.invoke(prompt:, model:, max_tokens:, stream: false) -> Result
    #
    # Result is a Struct with the following fields:
    #   - response_text [String]            text emitted by the provider
    #   - tokens_in     [Integer, nil]      input tokens (nil if unknown)
    #   - tokens_out    [Integer, nil]      output tokens (nil if unknown)
    #   - model_used    [String, nil]       resolved model identifier
    #   - raw           [Object, nil]       provider-specific payload
    #
    # Providers raise Hecks::LlmAdapterError on transport / parse / auth
    # failures. The dispatcher catches that and re-raises as the
    # structured Hecks::LlmInvocationFailed.
    #
    # Phase 2 step 4 ships the :test (fixture-backed) provider only.
    # Step 5 adds :claude and :ollama against this same interface.
    #
    module LlmProviders
      # Shape returned by every provider's #invoke.
      Result = Struct.new(
        :response_text,
        :tokens_in,
        :tokens_out,
        :model_used,
        :raw,
        keyword_init: true
      )
    end
  end
end

require "hecks/runtime/llm_providers/test_provider"
