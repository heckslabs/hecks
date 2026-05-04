# Hecks::LlmAdapterError / LlmInvocationSkipped / LlmInvocationFailed
#
# Errors raised (or returned) by Hecks::Runtime::LlmDispatcher when an
# LLM adapter invocation cannot proceed or fails. Mirrors the layout
# of Hecks::ShellAdapterError but distinguishes two non-success modes:
#
#   - Skipped: a non-raising sentinel returned to the caller when the
#     dispatcher chose not to invoke the provider (breaker open, budget
#     exceeded, provider unavailable). Surfaced as a Result-like object,
#     not via raise — callers branch on it.
#   - Failed: a real failure (transport error, auth, malformed
#     response). Raised so the call site can decide whether to retry.
#
# LlmAdapterError is the shared base; provider transport errors raise
# it directly. The two sub-types add a `:reason` slot for telemetry
# without forcing every caller to switch on message text.
#
#   raise Hecks::LlmAdapterError.new(
#     "claude transport: connection refused",
#     adapter: :speech, provider: :claude
#   )
#
#   skipped = Hecks::LlmInvocationSkipped.new(
#     adapter: :speech, reason: "breaker_open"
#   )
#
#   raise Hecks::LlmInvocationFailed.new(
#     "auth invalid",
#     adapter: :speech, provider: :claude, reason: "auth_invalid"
#   )
#
module Hecks
  # Raised by LLM providers on transport / parsing / auth failures.
  # The dispatcher catches this and re-raises as LlmInvocationFailed
  # with structured reason, so providers can stay terse.
  class LlmAdapterError < Error
    # @return [Symbol, nil] adapter name that failed
    attr_reader :adapter

    # @return [Symbol, nil] provider name (:claude, :ollama, :test, ...)
    attr_reader :provider

    def initialize(message = nil, adapter: nil, provider: nil)
      @adapter = adapter
      @provider = provider
      super(message)
    end

    # @return [Hash] structured payload for logs / events
    def as_json
      h = super
      h[:adapter] = adapter.to_s if adapter
      h[:provider] = provider.to_s if provider
      h
    end
  end

  # Returned (NOT raised) by LlmDispatcher when an invocation is
  # short-circuited before reaching the provider. The dispatcher
  # surfaces this so callers can branch on it without a rescue.
  #
  # Common reasons: "breaker_open", "budget_exceeded",
  # "provider_unavailable", "fixture_missing".
  class LlmInvocationSkipped < LlmAdapterError
    # @return [String, nil] short tag for why the call was skipped
    attr_reader :reason

    def initialize(message = nil, adapter: nil, provider: nil, reason: nil)
      @reason = reason
      msg = message || "llm adapter :#{adapter} skipped (#{reason})"
      super(msg, adapter: adapter, provider: provider)
    end

    def as_json
      h = super
      h[:reason] = reason.to_s if reason
      h
    end
  end

  # Raised when a provider invocation fails after dispatch began.
  # Distinct from Skipped because the caller did try to talk to the
  # provider — telemetry should account for it differently.
  #
  # Common reasons: "transport_error", "auth_invalid",
  # "rate_limited", "malformed_response", "timeout".
  class LlmInvocationFailed < LlmAdapterError
    # @return [String, nil] short tag for the failure mode
    attr_reader :reason

    def initialize(message = nil, adapter: nil, provider: nil, reason: nil)
      @reason = reason
      super(message, adapter: adapter, provider: provider)
    end

    def as_json
      h = super
      h[:reason] = reason.to_s if reason
      h
    end
  end
end
