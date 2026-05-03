require "hecks/runtime/llm_providers"

module Hecks
  class Runtime

    # Hecks::Runtime::LlmDispatcher
    #
    # Invokes a Hecksagon::Structure::LlmAdapter with runtime-provided
    # attributes through the i23 §4 gated pipeline :
    #
    #   1. CircuitBreaker.open?              → Skipped(reason: "breaker_open")
    #   2. Spend.over_budget?                → Skipped(reason: "budget_exceeded")
    #      (skipped when override_active?    → logs LlmInvocationOverbudgetBypass)
    #   3. substitute {{placeholders}}       → built prompt
    #   4. resolve_provider(backend)         → Skipped(reason: "provider_unavailable")
    #   5. provider.invoke(prompt:, model:, max_tokens:, stream:)
    #      ├─ success: Spend.record_call + CircuitBreaker.record_success
    #      │           + LlmInvocationCompleted log → Result
    #      └─ failure: CircuitBreaker.record_failure + LlmInvocationFailed log
    #                  → re-raise as Hecks::LlmInvocationFailed
    #
    # Crash ordering (i23 §4) : provider success + record_call failure still
    # returns the Result and emits LlmInvocationCompleted ; missing-record
    # beats lost-response. The reconcile daemon catches up.
    #
    # Mirrors Hecks::Runtime::ShellDispatcher in surface so callers can
    # swap one for the other through generic adapter-wiring. The
    # spend / breaker / logger ports are duck-typed and optional — when
    # absent, the dispatcher is a bare provider-invocation pipeline.
    #
    #   adapter = Hecksagon::Structure::LlmAdapter.new(
    #     name: :greet, prompt_template: "Hi {{name}}",
    #     model: "claude-sonnet-4", max_tokens: 50, backend: :test,
    #   )
    #   provider = Hecks::Runtime::LlmProviders::TestProvider.new(
    #     fixtures: { TestProvider.hash_for("Hi Miette") => "Hello, Miette." }
    #   )
    #   result = LlmDispatcher.call(
    #     adapter, { name: "Miette" }, providers: { test: provider }
    #   )
    #   result.response_text  # => "Hello, Miette."
    #
    module LlmDispatcher
      # Successful dispatch result. Provider response_text + prompt + token
      # telemetry. Mirrors ShellDispatcher::Result with LLM-native fields.
      Result = Struct.new(
        :response_text, :prompt, :provider, :model_used,
        :tokens_in, :tokens_out, :raw,
        keyword_init: true
      ) do
        def skipped? = false
        def completed? = true
      end

      # Returned (not raised) when the dispatcher refuses the call before the
      # provider invocation : breaker open, budget exceeded, or no provider.
      Skipped = Struct.new(:adapter_name, :reason, :details, keyword_init: true) do
        def skipped? = true
        def completed? = false
      end

      DEFAULT_BACKEND = :test

      module_function

      # Dispatch an LLM adapter through the gated pipeline.
      #
      # @param adapter [Hecksagon::Structure::LlmAdapter]
      # @param attrs [Hash] placeholder values
      # @param providers [Hash{Symbol=>#invoke}, nil] provider-name → provider instance
      # @param stream [Boolean] forwarded to provider
      # @param spend [#over_budget?, #record_call, nil] gating disabled when nil
      # @param breaker [#open?, #record_success, #record_failure, nil] gating disabled when nil
      # @param breaker_kind [String, Symbol, nil] override "#{adapter.name}_api" default
      # @param period [String, nil] spend bucket key (default UTC date)
      # @param logger [#<<, nil] event sink ; receives Hash entries
      # @param now [Time, nil] injectable clock
      # @return [Result, Skipped]
      # @raise [Hecks::LlmInvocationFailed] on provider transport failure
      def call(adapter, attrs = {}, providers: nil, stream: false,
               spend: nil, breaker: nil, breaker_kind: nil,
               period: nil, logger: nil, now: nil)
        kind   = (breaker_kind || "#{adapter.name}_api").to_s
        clock  = now || Time.now
        bucket = period || default_period(clock)

        if breaker && safe_call(breaker, :open?, default: false, kind: kind)
          return emit_skipped(adapter, "breaker_open", { kind: kind }, logger)
        end

        if spend
          if override_bypass?(spend, bucket, clock)
            log(logger, event: "LlmInvocationOverbudgetBypass",
                       adapter: adapter.name, period: bucket)
          elsif safe_call(spend, :over_budget?, default: false, period: bucket)
            return emit_skipped(adapter, "budget_exceeded", { period: bucket }, logger)
          end
        end

        prompt   = substitute_placeholders(adapter.prompt_template, attrs)
        backend  = (adapter.backend || DEFAULT_BACKEND).to_sym
        provider = resolve_provider(backend, providers)
        return provider if provider.is_a?(Skipped)

        invoke_with_recording(adapter, provider, backend, prompt, stream,
                              kind: kind, bucket: bucket, clock: clock,
                              spend: spend, breaker: breaker, logger: logger)
      end

      # Substitute {{name}} tokens — unknown placeholders left literal.
      def substitute_placeholders(template, attrs)
        sym_attrs = attrs.transform_keys(&:to_sym)
        template.to_s.gsub(Hecksagon::Structure::LlmAdapter::PLACEHOLDER_RE) do
          name = Regexp.last_match(1).to_sym
          sym_attrs.key?(name) ? sym_attrs[name].to_s : Regexp.last_match(0)
        end
      end

      # Resolve provider by backend. providers nil + :test → default TestProvider.
      # Otherwise unregistered → Skipped(provider_unavailable).
      def resolve_provider(backend, providers)
        if providers.is_a?(Hash) && providers.key?(backend)
          return providers[backend]
        end
        if providers.nil? && backend == :test
          return Hecks::Runtime::LlmProviders::TestProvider.new
        end
        Skipped.new(
          adapter_name: nil, reason: "provider_unavailable",
          details: { provider: backend }
        )
      end

      # Invoke provider with substituted prompt ; record success/failure into
      # spend + breaker ports per crash-ordering (record_* are best-effort).
      def invoke_with_recording(adapter, provider, backend, prompt, stream,
                                kind:, bucket:, clock:, spend:, breaker:, logger:)
        pres = provider.invoke(
          prompt: prompt, model: adapter.model,
          max_tokens: adapter.max_tokens, stream: stream
        )
        result = Result.new(
          response_text: pres.response_text, prompt: prompt, provider: backend,
          model_used: pres.model_used || adapter.model,
          tokens_in: pres.tokens_in, tokens_out: pres.tokens_out, raw: pres.raw
        )
        record_success(adapter, result, kind: kind, bucket: bucket,
                       clock: clock, spend: spend, breaker: breaker, logger: logger)
        result
      rescue Hecks::LlmInvocationFailed => e
        record_failure(kind, breaker, logger, e)
        raise
      rescue Hecks::LlmAdapterError => e
        record_failure(kind, breaker, logger, e)
        raise Hecks::LlmInvocationFailed.new(
          e.message,
          adapter: adapter.name, provider: backend, reason: "transport_error"
        )
      end

      def record_success(adapter, result, kind:, bucket:, clock:,
                         spend:, breaker:, logger:)
        if spend
          safe_invoke(spend, :record_call, logger,
                      on_error: "spend_record_call_failed",
                      provider: result.provider.to_s,
                      tokens_in: result.tokens_in.to_i,
                      tokens_out: result.tokens_out.to_i,
                      command_ref: adapter.response_into_target.to_s,
                      recorded_at: clock.iso8601)
        end
        if breaker
          safe_invoke(breaker, :record_success, logger,
                      on_error: "breaker_record_success_failed", kind: kind)
        end
        log(logger, event: "LlmInvocationCompleted",
                   adapter: adapter.name, period: bucket,
                   tokens_in: result.tokens_in, tokens_out: result.tokens_out)
      end

      def record_failure(kind, breaker, logger, error)
        if breaker
          safe_invoke(breaker, :record_failure, logger,
                      on_error: "breaker_record_failure_failed", kind: kind)
        end
        log(logger, event: "LlmInvocationFailed",
                   error_class: error.class.name, error_message: error.message)
      end

      def override_bypass?(spend, period, clock)
        return false unless spend.respond_to?(:override_active?)
        safe_call(spend, :override_active?, default: false,
                  period: period, now: clock)
      end

      def emit_skipped(adapter, reason, details, logger)
        log(logger, event: "LlmInvocationSkipped",
                   adapter: adapter.name, reason: reason, **details)
        Skipped.new(adapter_name: adapter.name, reason: reason, details: details)
      end

      def safe_call(port, method, default:, **kwargs)
        return default unless port.respond_to?(method)
        port.public_send(method, **kwargs)
      rescue
        default
      end

      def safe_invoke(port, method, logger, on_error:, **kwargs)
        return false unless port.respond_to?(method)
        port.public_send(method, **kwargs)
        true
      rescue => e
        log(logger, event: on_error, error_class: e.class.name,
                   error_message: e.message)
        false
      end

      def log(logger, payload)
        return unless logger
        logger << payload if logger.respond_to?(:<<)
      end

      def default_period(clock)
        clock.utc.strftime("%Y-%m-%d")
      end
    end
  end
end
