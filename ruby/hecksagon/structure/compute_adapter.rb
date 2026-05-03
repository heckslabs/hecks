module Hecksagon
  module Structure

    # Hecksagon::Structure::ComputeAdapter
    #
    # i220 sub-gap 5 (compute-adapter-primitive) — value object for a
    # named compute-binding adapter declared in a hecksagon. Sibling of
    # Hecksagon::Structure::LlmAdapter for local computation : where
    # `:llm` adapters substitute a prompt and call a model, `:compute`
    # adapters resolve a `function_name` against the runtime's built-in
    # function registry and chain the returned string into a target
    # command's attribute.
    #
    # Mirrors rust/src/hecksagon_ir.rs :: ComputeAdapter. The parity
    # suite's canonical dump (parity/canonical_ir.rb ::
    # dump_compute_adapter) emits the same shape both halves produce.
    #
    # Phase 1 lands this IR + DSL + Rust parser + parity wiring +
    # ONE concrete consumer (i227 MusingMint context) — broader
    # consumer wave (interpret_dream / wake_review jq pipelines)
    # is follow-on work.
    #
    #   adapter = ComputeAdapter.new(
    #     name: :recent_musings_summary,
    #     function_name: "summarize_recent_musings",
    #     trigger_on: "MusingMint.RequestMint",
    #     response_into_target: "MusingMint.MintMusing",
    #     response_into_attr: :recent_musings_summary,
    #   )
    #
    class ComputeAdapter
      attr_reader :name, :function_name, :trigger_on,
                  :response_into_target, :response_into_attr

      def initialize(name:, function_name: "", trigger_on: nil,
                     response_into_target: nil, response_into_attr: nil)
        raise ArgumentError, "compute adapter requires :name" if name.nil?
        @name = name.to_sym
        @function_name = function_name.to_s
        @trigger_on = trigger_on.nil? ? nil : trigger_on.to_s
        @response_into_target = response_into_target.nil? ? nil : response_into_target.to_s
        @response_into_attr = response_into_attr.nil? ? nil : response_into_attr.to_sym
      end

      # Effective trigger target — `trigger_on` when set ; otherwise
      # `response_into_target` (the historical default that kept
      # trigger and response identical, matching LlmAdapter).
      def effective_trigger
        @trigger_on || @response_into_target
      end

      # Hash representation for JSON / IR dumps. Mirrors the canonical
      # shape main.rs :: dump_hecksagon_json emits.
      def to_h
        {
          name: @name,
          function_name: @function_name,
          trigger_on: @trigger_on,
          response_into_target: @response_into_target,
          response_into_attr: @response_into_attr,
        }
      end
    end
  end
end
