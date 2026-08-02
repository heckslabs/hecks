require "json"

# The whole framework, deliberately: booting a grammar chapter exercises
# the DSL, the meta-validator, and the runtime — and nothing the entry
# point loads ever requires this file back, so the require is acyclic.
require_relative "../hecksagain"

module Hecksagain
  # The sublanguage grammar domains (grammar/*.bluebook) and the one boot
  # path for reading them as DATA — the expression chapter replayed
  # through its own admission ledger, so anything derived from it (the
  # operator projections, the conformance specs) reads the set that
  # actually survived the Admit gates, never a hand-copied list.
  #
  # Booted on CALL, never at require: the Prism adapter normalises every
  # predicate through CanonicalForm while a bluebook loads, so the
  # expression machinery cannot boot the chapter that configures it —
  # this module exists precisely so generators and specs boot it in a
  # scratch registry instead.
  module Grammar
    DIR    = File.expand_path("grammar", __dir__)
    LEDGER = File.join(DIR, "expression_operators.json")

    module_function

    # Boot the expression chapter and replay the admission ledger through
    # its real commands. A refused step raises — a generator running off
    # a half-admitted ledger would project a table the gates never
    # accepted.
    def expression
      registry = Runtime::Registry.new
      root = File.expand_path("../..", __dir__)
      Hecksagain.with_registry(registry) do
        Kernel.load(File.join(root, "lib/hecksagain/ports/persistence.port"))
        Kernel.load(File.join(root, "lib/hecksagain/ports/extraction.port"))
        Kernel.load(File.join(root, "lib/hecksagain/adapters/driven/memory.adapter"))
        Kernel.load(File.join(root, "lib/hecksagain/adapters/driven/prism.adapter"))
        Kernel.load(File.join(DIR, "expression.bluebook"))
      end
      dispatcher = Runtime::Dispatcher.new(registry)

      JSON.parse(File.read(LEDGER)).fetch("steps").each do |step|
        args = symbolize(step.fetch("args"))
        begin
          dispatcher.dispatch(step.fetch("verb"), **args)
        rescue *Runtime::DOMAIN_REFUSALS => refusal
          raise Runtime::WiringError,
                "the admission ledger refused at #{step['verb']} #{step['args']} — #{refusal.message}"
        end
      end

      dispatcher
    end

    def admitted_operators(dispatcher = expression)
      records(dispatcher, "Operator").select { |op| op[:status] == "admitted" }.map do |op|
        { symbol: op[:symbol].value, category: op[:category].value,
          precedence: op[:precedence].value, arity: op[:arity].value,
          renderings: Array(op[:renderings]).map { |r| { target: r[:target], form: r[:form] } } }
      end
    end

    def admitted_normalisations(dispatcher = expression)
      records(dispatcher, "Normalisation")
        .select { |rule| rule[:status] == "admitted" }
        .sort_by { |rule| rule[:position].value }
        .map do |rule|
          { strategy: rule[:strategy].value, source_token: rule[:source_token].value,
            replacement: rule[:replacement].value, boundary: rule[:boundary].value,
            position: rule[:position].value }
        end
    end

    def records(dispatcher, aggregate_name)
      registry  = dispatcher.registry
      aggregate = registry.bluebook("Expression").aggregate(aggregate_name)
      registry.repository("Expression", aggregate).all
    end

    def symbolize(value)
      case value
      when Hash  then value.to_h { |k, v| [k.to_sym, symbolize(v)] }
      when Array then value.map { |v| symbolize(v) }
      else value
      end
    end
  end
end
