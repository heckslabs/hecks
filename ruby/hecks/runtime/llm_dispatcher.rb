require "hecks/runtime/llm_providers"

module Hecks
  class Runtime

    # Hecks::Runtime::LlmDispatcher
    #
    # Invokes a Hecksagon::Structure::LlmAdapter with runtime-provided
    # attributes. Mirrors Hecks::Runtime::ShellDispatcher in shape ; the
    # call surface is intentionally identical so callers can swap one
    # for the other through generic adapter-wiring.
    #
    # Pipeline (this step) :
    #   1. substitute {{placeholder}} tokens in adapter.prompt_template
    #   2. resolve provider (look up by adapter.backend ; default :test)
    #   3. provider.invoke(prompt:, model:, max_tokens:, stream:)
    #   4. wrap into a Result (response_text, prompt, provider, tokens, raw)
    #
    # Out of scope here (siblings own these — do not couple) :
    #   - CircuitBreaker gating (step 6)
    #   - Spend / budget gating (step 6)
    #   - PromptScaffolder (step 7) — for now the prompt_template IS the prompt
    #   - boot-time provider registration (step 8) — providers passed in via
    #     `providers:` kwarg or constructed default-:test
    #
    #   adapter = Hecksagon::Structure::LlmAdapter.new(
    #     name: :greet,
    #     prompt_template: "Hi {{name}}",
    #     model: "claude-sonnet-4",
    #     max_tokens: 50,
    #     backend: :test,
    #   )
    #   provider = Hecks::Runtime::LlmProviders::TestProvider.new(
    #     fixtures: {
    #       Hecks::Runtime::LlmProviders::TestProvider.hash_for("Hi Miette") =>
    #         "Hello, Miette."
    #     }
    #   )
    #   result = Hecks::Runtime::LlmDispatcher.call(
    #     adapter, { name: "Miette" }, providers: { test: provider }
    #   )
    #   result.response_text  # => "Hello, Miette."
    #   result.prompt         # => "Hi Miette"
    #   result.provider       # => :test
    #   result.tokens_in      # => 2
    #   result.tokens_out     # => 2
    #
    module LlmDispatcher
      # Return shape for a successful dispatch. Mirrors ShellDispatcher
      # Result but renames stdout-style fields to LLM-native ones.
      Result = Struct.new(
        :response_text,
        :prompt,
        :provider,
        :model_used,
        :tokens_in,
        :tokens_out,
        :raw,
        keyword_init: true
      )

      # Default backend used when adapter.backend is nil.
      DEFAULT_BACKEND = :test

      module_function

      # Dispatch an LLM adapter.
      #
      # @param adapter [Hecksagon::Structure::LlmAdapter]
      # @param attrs [Hash{Symbol=>Object}] values substituted into {{placeholders}}
      # @param providers [Hash{Symbol=>#invoke}, nil] provider-name -> provider instance.
      #   When nil, a single default :test provider is constructed (no fixtures, lenient).
      # @param stream [Boolean] forwarded to provider (this step ignores chunks)
      # @return [Result]
      # @raise [Hecks::LlmInvocationFailed] on provider transport failure
      # @return [Hecks::LlmInvocationSkipped] (NOT raised) when no provider can be resolved
      def call(adapter, attrs = {}, providers: nil, stream: false)
        prompt = substitute_placeholders(adapter.prompt_template, attrs)
        backend = (adapter.backend || DEFAULT_BACKEND).to_sym
        provider = resolve_provider(backend, providers)

        return provider if provider.is_a?(Hecks::LlmInvocationSkipped)

        invoke_and_wrap(adapter, provider, backend, prompt, stream)
      end

      # Substitute {{name}} tokens in +template+ from +attrs+.
      # Unknown placeholders are left literal (mirrors ShellDispatcher).
      # Accepts string-or-symbol keys.
      #
      # @param template [String]
      # @param attrs [Hash]
      # @return [String]
      def substitute_placeholders(template, attrs)
        sym_attrs = attrs.transform_keys(&:to_sym)
        template.to_s.gsub(Hecksagon::Structure::LlmAdapter::PLACEHOLDER_RE) do
          name = Regexp.last_match(1).to_sym
          sym_attrs.key?(name) ? sym_attrs[name].to_s : Regexp.last_match(0)
        end
      end

      # Resolve a provider by backend name. When +providers+ is nil and
      # backend is :test, construct a default lenient TestProvider so
      # specs can dispatch without wiring. Anything else without a
      # registered provider returns LlmInvocationSkipped(provider_unavailable).
      #
      # @param backend [Symbol]
      # @param providers [Hash, nil]
      # @return [#invoke, Hecks::LlmInvocationSkipped]
      def resolve_provider(backend, providers)
        if providers.is_a?(Hash) && providers.key?(backend)
          return providers[backend]
        end
        if providers.nil? && backend == :test
          return Hecks::Runtime::LlmProviders::TestProvider.new
        end
        Hecks::LlmInvocationSkipped.new(
          provider: backend, reason: "provider_unavailable"
        )
      end

      # Invoke +provider+ with the substituted prompt and wrap the
      # provider Result into a dispatcher Result.
      #
      # Provider is expected to raise Hecks::LlmAdapterError on
      # transport failure. We re-raise as LlmInvocationFailed with a
      # structured reason so consumers don't have to switch on message
      # text.
      #
      # @return [Result]
      # @raise [Hecks::LlmInvocationFailed]
      def invoke_and_wrap(adapter, provider, backend, prompt, stream)
        pres = provider.invoke(
          prompt: prompt,
          model: adapter.model,
          max_tokens: adapter.max_tokens,
          stream: stream
        )
        Result.new(
          response_text: pres.response_text,
          prompt: prompt,
          provider: backend,
          model_used: pres.model_used || adapter.model,
          tokens_in: pres.tokens_in,
          tokens_out: pres.tokens_out,
          raw: pres.raw
        )
      rescue Hecks::LlmInvocationFailed
        # Already structured (e.g. fixture_missing from TestProvider) ;
        # let it propagate untouched.
        raise
      rescue Hecks::LlmAdapterError => e
        raise Hecks::LlmInvocationFailed.new(
          e.message,
          adapter: adapter.name,
          provider: backend,
          reason: "transport_error"
        )
      end
    end
  end
end
