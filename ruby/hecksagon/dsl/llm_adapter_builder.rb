module Hecksagon
  module DSL

    # Hecksagon::DSL::LlmAdapterBuilder
    #
    # DSL builder for a single LLM-binding adapter. Collects prompt
    # template, model identifier, max_tokens budget, response routing
    # target, and optional backend declared inside an
    # `adapter :llm, name:` block.
    #
    #   builder = LlmAdapterBuilder.new(:dream_image)
    #   builder.prompt_template "You are Miette dreaming...\n{{seed_image}}\n"
    #   builder.model "claude-sonnet-4"
    #   builder.max_tokens 200
    #   builder.response_into "Dream.ProduceImage", attr: :text_fr
    #   builder.backend :claude
    #   builder.build  # => Hecksagon::Structure::LlmAdapter
    #
    # Mirrors ShellAdapterBuilder's shape — block setters + apply_options
    # for one-liner kwargs. The Rust hecksagon_parser parses the same
    # surface ; both halves produce equivalent canonical IR through
    # parity/canonical_ir.rb :: dump_llm_adapter.
    #
    class LlmAdapterBuilder
      def initialize(name)
        @name = name&.to_sym
        @prompt_template = ""
        @model = nil
        @max_tokens = nil
        @trigger_on = nil
        @response_into_target = nil
        @response_into_attr = nil
        @backend = nil
      end

      # i228 — declare the dispatch target that fires this adapter,
      # independently of `response_into` (where the LLM's reply is
      # routed). When omitted the runtime falls back to the
      # response_into target so the historical self-triggering shape
      # keeps working without per-adapter declaration.
      #
      #   trigger_on "Dream.ProduceImage"           # fires on PM cascade
      #   response_into "Dream.RecordImage", attr: :text_fr
      def trigger_on(target)
        @trigger_on = target.to_s
      end

      # Declare the prompt template — heredocs welcome. May contain
      # `{{placeholder}}` tokens that the Phase 2 runtime will substitute
      # at dispatch time.
      def prompt_template(text)
        @prompt_template = text.to_s
      end

      # Declare the model identifier (e.g. "claude-sonnet-4").
      def model(name)
        @model = name.to_s
      end

      # Declare the max_tokens budget for the response.
      def max_tokens(n)
        @max_tokens = Integer(n)
      end

      # Declare where the LLM response is routed.
      #
      #   response_into "Dream.ProduceImage", attr: :text_fr
      #
      # The first positional is the dotted "Aggregate.Command" target.
      # The :attr keyword names the attribute on that command which
      # receives the LLM's text payload.
      def response_into(target, attr: nil)
        @response_into_target = target.to_s
        @response_into_attr = attr.nil? ? nil : attr.to_sym
      end

      # Declare which LLM backend to bind. Today recognised: :claude,
      # :ollama, :fixture. Phase 2 wires the actual API calls.
      def backend(name)
        @backend = name.to_sym
      end

      # Apply keyword-argument shortcuts from the one-liner form.
      def apply_options(opts)
        prompt_template(opts[:prompt_template]) if opts.key?(:prompt_template)
        model(opts[:model])                     if opts.key?(:model)
        max_tokens(opts[:max_tokens])           if opts.key?(:max_tokens)
        trigger_on(opts[:trigger_on])           if opts.key?(:trigger_on)
        backend(opts[:backend])                 if opts.key?(:backend)
        if opts.key?(:response_into)
          target = opts[:response_into]
          attr = opts[:response_attr]
          response_into(target, attr: attr)
        end
        self
      end

      def build
        Structure::LlmAdapter.new(
          name: @name,
          prompt_template: @prompt_template,
          model: @model,
          max_tokens: @max_tokens,
          trigger_on: @trigger_on,
          response_into_target: @response_into_target,
          response_into_attr: @response_into_attr,
          backend: @backend,
        )
      end
    end
  end
end
