require "json"

# Loads the whole framework on purpose; nothing the entry point loads
# requires this file back, so the require is acyclic.
require_relative "../hecks"
require_relative "grammar/operators"

module Hecks
  # The sublanguage grammar domains (grammar/*.bluebook) and the one boot path
  # for reading them as data, replayed through the expression admission ledger.
  #
  # Booted on call, never at require: the Prism adapter normalises predicates
  # while a bluebook loads, so the expression machinery cannot boot its own chapter.
  module Grammar
    DIR    = File.expand_path("grammar", __dir__)
    LEDGER = File.join(DIR, "expression_operators.json")

    # The ports and adapters a chapter needs loaded before its own bluebook, relative to the
    # repository root.
    CHAPTER_PREREQUISITES = %w[lib/hecks/ports/persistence.port lib/hecks/ports/extraction.port
                               lib/hecks/adapters/driven/memory.adapter
                               lib/hecks/adapters/driven/prism.adapter].freeze

    extend Operators

    module_function

    # Boots the expression chapter and replays the admission ledger through
    # its real commands; a refused step raises.
    #
    # @return [Runtime::Dispatcher] the dispatcher bound to the booted, replayed
    #   expression chapter
    # @raise [Runtime::WiringError] if a ledger step is refused by the chapter's
    #   own domain rules
    def expression
      registry = Runtime::Registry.new
      load_chapter(registry, File.join(DIR, "expression.bluebook"))
      dispatcher = Runtime::Dispatcher.new(registry)
      JSON.parse(File.read(LEDGER)).fetch("steps").each { |step| replay_step(dispatcher, step) }
      dispatcher
    end

    # Loads a chapter's bluebook into a registry, after the ports and adapters it needs.
    #
    # @param registry [Runtime::Registry] the registry the chapter loads into
    # @param chapter [String] the path of the chapter's `.bluebook`
    # @return [void]
    def load_chapter(registry, chapter)
      root = File.expand_path("../..", __dir__)
      Hecks.with_registry(registry) do
        CHAPTER_PREREQUISITES.each { |file| Kernel.load(File.join(root, file)) }
        Kernel.load(chapter)
      end
    end

    # Dispatches one admission-ledger step.
    #
    # @param dispatcher [Runtime::Dispatcher] the dispatcher bound to the expression chapter
    # @param step [Hash] a ledger step, with `"verb"` and `"args"`
    # @return [void]
    # @raise [Runtime::WiringError] if the chapter's own domain rules refuse the step
    def replay_step(dispatcher, step)
      dispatcher.dispatch_flat(step.fetch("verb"), symbolize(step.fetch("args")))
    rescue *Runtime::DOMAIN_REFUSALS => e
      raise Runtime::WiringError,
            "the admission ledger refused at #{step["verb"]} #{step["args"]} — #{e.message}"
    end

    # Reads every admitted operator from the ledger's replayed chapter.
    #
    # @param dispatcher [Runtime::Dispatcher] a dispatcher bound to the booted
    #   expression chapter; defaults to booting and replaying a fresh one
    # @return [Array<Hash>] one Hash per admitted operator, with `:symbol`,
    #   `:category`, `:precedence`, `:arity`, and `:renderings` (an Array of
    #   `{target:, form:}` Hashes)
    def admitted_operators(dispatcher = expression)
      records(dispatcher, "Operator").select { |op| op[:status] == "admitted" }.map { |op| operator_row(op) }
    end

    # @param operator [Runtime::Instance] an admitted `Operator` record
    # @return [Hash] its symbol, category, precedence, arity and renderings
    def operator_row(operator)
      { symbol: operator[:symbol].value, category: operator[:category].value,
        precedence: operator[:precedence].value, arity: operator[:arity].value,
        renderings: Array(operator[:renderings]).map { |r| { target: r[:target], form: r[:form] } } }
    end

    # Reads every admitted normalisation rule from the ledger's replayed
    # chapter, in position order.
    #
    # @param dispatcher [Runtime::Dispatcher] a dispatcher bound to the booted
    #   expression chapter; defaults to booting and replaying a fresh one
    # @return [Array<Hash>] one Hash per admitted rule, with `:strategy`,
    #   `:source_token`, `:replacement`, `:boundary`, and `:position`
    def admitted_normalisations(dispatcher = expression)
      records(dispatcher, "Normalisation")
        .select { |rule| rule[:status] == "admitted" }
        .sort_by { |rule| rule[:position].value }
        .map { |rule| normalisation_row(rule) }
    end

    # @param rule [Runtime::Instance] an admitted `Normalisation` record
    # @return [Hash] its strategy, source token, replacement, boundary and position
    def normalisation_row(rule)
      { strategy: rule[:strategy].value, source_token: rule[:source_token].value,
        replacement: rule[:replacement].value, boundary: rule[:boundary].value,
        position: rule[:position].value }
    end

    # Reads every record of one aggregate from the expression chapter's own
    # repository.
    #
    # @param dispatcher [Runtime::Dispatcher] a dispatcher bound to the booted
    #   expression chapter
    # @param aggregate_name [String] the aggregate's declared name, such as
    #   `"Operator"`
    # @return [Array<Runtime::Instance>] every stored instance of the aggregate
    def records(dispatcher, aggregate_name)
      registry  = dispatcher.registry
      aggregate = registry.bluebook("Expression").aggregate(aggregate_name)
      registry.repository("Expression", aggregate).all
    end

    # Deep-symbolizes a JSON-decoded value's Hash keys.
    #
    # @param value [Object] a Hash, Array, or scalar decoded from JSON
    # @return [Object] `value` with every Hash key (recursively) converted to a Symbol
    def symbolize(value)
      case value
      when Hash  then value.to_h { |k, v| [k.to_sym, symbolize(v)] }
      when Array then value.map { |v| symbolize(v) }
      else value
      end
    end
  end
end
