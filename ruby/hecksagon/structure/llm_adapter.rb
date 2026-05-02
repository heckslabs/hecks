module Hecksagon
  module Structure

    # Hecksagon::Structure::LlmAdapter
    #
    # Value object for a named LLM-binding adapter declared in a hecksagon.
    # Holds the prompt template (with {{placeholder}} tokens), the model
    # identifier, the max_tokens budget, the routing target for the
    # response (an "Aggregate.Command" path + the attribute name on that
    # command that receives the LLM's text), and an optional backend
    # (:claude, :ollama, :fixture) to disambiguate when multiple LLM
    # backends are wired into the runtime.
    #
    # Mirrors rust/src/hecksagon_ir.rs :: LlmAdapter. The parity suite's
    # canonical dump (parity/canonical_ir.rb :: dump_llm_adapter) emits
    # the same shape both halves produce.
    #
    # Phase 1 lands this IR + DSL + Rust parser + parity fixture only.
    # Phase 2 wires the runtime adapter that actually calls Claude /
    # Ollama with the prompt and routes the response into the named
    # command on the named aggregate.
    #
    #   adapter = LlmAdapter.new(
    #     name: :dream_image,
    #     prompt_template: "You are Miette dreaming...\n{{seed_image}}\n",
    #     model: "claude-sonnet-4",
    #     max_tokens: 200,
    #     response_into_target: "Dream.ProduceImage",
    #     response_into_attr: :text_fr,
    #     backend: :claude,
    #   )
    #   adapter.placeholders  # => [:seed_image]
    #
    class LlmAdapter
      PLACEHOLDER_RE = /\{\{(\w+)\}\}/

      attr_reader :name, :prompt_template, :model, :max_tokens,
                  :response_into_target, :response_into_attr, :backend

      def initialize(name:, prompt_template: "", model: nil, max_tokens: nil,
                     response_into_target: nil, response_into_attr: nil,
                     backend: nil)
        raise ArgumentError, "llm adapter requires :name" if name.nil?
        @name = name.to_sym
        @prompt_template = prompt_template.to_s
        @model = model.nil? ? nil : model.to_s
        @max_tokens = max_tokens.nil? ? nil : Integer(max_tokens)
        @response_into_target = response_into_target.nil? ? nil : response_into_target.to_s
        @response_into_attr = response_into_attr.nil? ? nil : response_into_attr.to_sym
        @backend = backend.nil? ? nil : backend.to_sym
      end

      # Unique placeholder names referenced in the prompt_template,
      # in first-appearance order. Mirrors ShellAdapter#placeholders.
      def placeholders
        seen = []
        @prompt_template.scan(PLACEHOLDER_RE).flatten.each do |match|
          sym = match.to_sym
          seen << sym unless seen.include?(sym)
        end
        seen
      end

      # Hash representation for JSON / IR dumps.
      def to_h
        {
          name: @name,
          prompt_template: @prompt_template,
          model: @model,
          max_tokens: @max_tokens,
          response_into_target: @response_into_target,
          response_into_attr: @response_into_attr,
          backend: @backend,
        }
      end
    end
  end
end
