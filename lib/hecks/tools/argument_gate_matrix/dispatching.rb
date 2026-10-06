# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module ArgumentGateMatrix
      # Dispatches candidate rows against a booted domain and reads Ruby's dispatch trace to see
      # which gate refused.
      module Dispatching
        def order_for(kind) = kind == "entity" ? ENTITY_ORDER : AGGREGATE_ORDER

        # The first declared step missing from the dispatch trace is the one that refused.
        def refused_step(kind)
          interpreter = kind == "entity" ? Hecks::Runtime::EntityInterpreter : Hecks::Runtime::CommandInterpreter
          ran = interpreter.trace || []
          # `decode_arguments` never traces, so it must not be read as the refusing step.
          order_for(kind).reject { |step| step == "decode_arguments" }.find { |step| !ran.include?(step.to_sym) }
        end

        # Dispatches one row; returns [refusal class, message, refused step], or nils if it
        # succeeded.
        def run_row(runtime, row, kind)
          with_traces { attempt(runtime, row, kind) }
        end

        # Sorts a row by what Ruby did with it.
        #
        # @return [Array(Symbol, Hash)] `:kept` or `:dropped`, and the row with its verdict added
        def judge(runtime, row, domain)
          kind, error, refused = run_row(runtime, row, row[:kind])
          if kind.nil?
            [:dropped, row.merge(reason: "Ruby accepted it — neither gate refused")]
          elsif refused.to_s != row[:pair].first
            [:dropped, row.merge(reason: "Ruby refused at #{refused.inspect} (#{kind}), not the earlier declared step")]
          else
            [:kept, row.merge(domain: domain, expected: { "kind" => kind, "error" => error, "refused_at" => refused.to_s })]
          end
        end

        private

        # Records the dispatch trace of both interpreters while the block runs.
        def with_traces
          Hecks::Runtime::CommandInterpreter.trace = []
          Hecks::Runtime::EntityInterpreter.trace = []
          yield
        ensure
          Hecks::Runtime::CommandInterpreter.trace = nil
          Hecks::Runtime::EntityInterpreter.trace = nil
        end

        def attempt(runtime, row, kind)
          args = JSON.parse(JSON.generate(row[:args])).transform_keys(&:to_sym)
          dispatch_row(runtime, row, args)
          [nil, nil, nil]
        rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
          [e.class.name.split("::").last, e.message, refused_step(kind)]
        end

        def dispatch_row(runtime, row, args)
          return runtime.dispatch_flat(row[:verb], args) unless row[:role]

          Hecks.as_caller(role: row[:role]) { runtime.dispatch_flat(row[:verb], args) }
        end
      end
    end
  end
end
