module Hecksagon
  module DSL

    # Hecksagon::DSL::ComputeAdapterBuilder
    #
    # i220 sub-gap 5 (compute-adapter-primitive) — DSL builder for a
    # single compute-binding adapter. Mirror of LlmAdapterBuilder for
    # local computation : collects a `function` name (the registry key
    # the runtime resolves at dispatch time), an optional `trigger_on`
    # target, and a `response_into` (target + attr) routing.
    #
    #   builder = ComputeAdapterBuilder.new(:recent_musings_summary)
    #   builder.function "summarize_recent_musings"
    #   builder.trigger_on "MusingMint.RequestMint"
    #   builder.response_into "MusingMint.MintMusing", attr: :recent_musings_summary
    #   builder.build  # => Hecksagon::Structure::ComputeAdapter
    #
    # The Rust hecksagon_parser parses the same surface ; both halves
    # produce equivalent canonical IR through parity/canonical_ir.rb
    # :: dump_compute_adapter.
    #
    class ComputeAdapterBuilder
      def initialize(name)
        @name = name&.to_sym
        @function_name = ""
        @trigger_on = nil
        @response_into_target = nil
        @response_into_attr = nil
      end

      # Declare the function name (the compute_functions registry
      # key the runtime resolves). Accepts either a string or a
      # symbol — both canonicalize to the bare identifier.
      def function(name)
        @function_name = name.to_s
      end

      # Declare the dispatch target that fires this adapter. When
      # omitted the runtime falls back to the response_into target,
      # mirroring LlmAdapter's effective_trigger semantics.
      #
      #   trigger_on "MusingMint.RequestMint"
      def trigger_on(target)
        @trigger_on = target.to_s
      end

      # Declare where the function's returned string is routed.
      #
      #   response_into "MusingMint.MintMusing", attr: :recent_musings_summary
      def response_into(target, attr: nil)
        @response_into_target = target.to_s
        @response_into_attr = attr.nil? ? nil : attr.to_sym
      end

      # Apply keyword-argument shortcuts from the one-liner form.
      def apply_options(opts)
        function(opts[:function])    if opts.key?(:function)
        trigger_on(opts[:trigger_on]) if opts.key?(:trigger_on)
        if opts.key?(:response_into)
          target = opts[:response_into]
          # i220 sub-gap 5 heal : the one-liner kwarg form uses `attr:`
          # (matches the .hecksagon DSL surface and the Rust parser's
          # `attr` key). Earlier shape mistakenly looked up :response_attr
          # which never appears in the one-liner form, so apply_options
          # silently dropped attr and Ruby canonical_ir emitted null
          # while Rust emitted the real value — caught at main-scope
          # hecksagon parity for body/wake/wake_review.hecksagon's
          # :compute :dream_corpus_window adapter.
          attr = opts[:attr]
          response_into(target, attr: attr)
        end
        self
      end

      def build
        Structure::ComputeAdapter.new(
          name: @name,
          function_name: @function_name,
          trigger_on: @trigger_on,
          response_into_target: @response_into_target,
          response_into_attr: @response_into_attr,
        )
      end
    end
  end
end
