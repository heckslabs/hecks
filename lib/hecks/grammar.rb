require "json"

# The whole framework, deliberately: booting a grammar chapter exercises
# the DSL, the meta-validator, and the runtime — and nothing the entry
# point loads ever requires this file back, so the require is acyclic.
require_relative "../hecks"

module Hecks
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
      Hecks.with_registry(registry) do
        Kernel.load(File.join(root, "lib/hecks/ports/persistence.port"))
        Kernel.load(File.join(root, "lib/hecks/ports/extraction.port"))
        Kernel.load(File.join(root, "lib/hecks/adapters/driven/memory.adapter"))
        Kernel.load(File.join(root, "lib/hecks/adapters/driven/prism.adapter"))
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

    # THE OPERATORS THE LANGUAGE STANDS ON. Every guard and invariant in
    # the language's own chapters — the meta-domain (Bluebook, World) and
    # the grammar chapters beside this file — evaluates through the very
    # operator table the ledger admits. An operator one of those
    # predicates uses is SELF-BEARING: retire it and the language can no
    # longer read its own rules — found the hard way, as a projection
    # missing `!=` that could not boot the chapter to fix itself. This
    # derives the set, with a usage site per operator, so the generator
    # and the conformance spec can refuse the retirement BY NAME instead
    # of wedging.
    def self_bearing_operators
      sites = Hash.new { |h, k| h[k] = [] }

      chapters = Bluebook::MetaValidator.grammar_registry
                                        .then { |reg| %w[Bluebook World].map { |name| reg.bluebook(name) } }
      chapters += grammar_chapters

      chapters.compact.each do |chapter|
        chapter.aggregates.each do |aggregate|
          aggregate.commands.each do |command|
            command.givens.each do |given|
              operators_in(given.canonical).each do |symbol|
                sites[symbol] << "#{chapter.name} #{aggregate.name}.#{command.hecks_name}"
              end
            end
          end
          aggregate.value_objects.each do |value_object|
            value_object.invariants.each do |invariant|
              operators_in(invariant.canonical).each do |symbol|
                sites[symbol] << "#{chapter.name} #{aggregate.name}::#{value_object.hecks_name}"
              end
            end
          end
        end
      end

      sites.transform_values(&:uniq)
    end

    # Every grammar/*.bluebook chapter, booted the same way the corpus
    # boots them — each alone, in a scratch registry.
    def grammar_chapters
      Dir[File.join(DIR, "*.bluebook")].sort.map do |chapter|
        registry = Runtime::Registry.new
        root = File.expand_path("../..", __dir__)
        Hecks.with_registry(registry) do
          Kernel.load(File.join(root, "lib/hecks/ports/persistence.port"))
          Kernel.load(File.join(root, "lib/hecks/ports/extraction.port"))
          Kernel.load(File.join(root, "lib/hecks/adapters/driven/memory.adapter"))
          Kernel.load(File.join(root, "lib/hecks/adapters/driven/prism.adapter"))
          Kernel.load(chapter)
        end
        registry.bluebooks.values.first
      end
    end

    # Which admitted operators one canonical text evaluates through —
    # the evaluator's own parse, walked for its operator nodes, leaves
    # walked for the resolver's arithmetic.
    def operators_in(canonical)
      evaluator = Bluebook::Expression::Evaluator
      node = begin
        evaluator.parse(canonical)
      rescue StandardError
        return []
      end
      walk_operators(node, evaluator).uniq
    end

    def walk_operators(node, evaluator)
      resolver = Bluebook::Expression::Resolver
      case node
      when evaluator::Or  then ["||"] + walk_operators(node.left, evaluator) + walk_operators(node.right, evaluator)
      when evaluator::And then ["&&"] + walk_operators(node.left, evaluator) + walk_operators(node.right, evaluator)
      when evaluator::Not then ["!"] + walk_operators(node.node, evaluator)
      when evaluator::Compare
        [node.operator.symbol] + walk_operators(node.left, evaluator) + walk_operators(node.right, evaluator)
      when evaluator::Include
        [".include?"] + walk_operators(node.haystack, evaluator) + walk_operators(node.needle, evaluator)
      when evaluator::Resolve then walk_operators(node.expr, evaluator)
      when resolver::Addition then ["+"] + walk_operators(node.left, evaluator) + walk_operators(node.right, evaluator)
      when resolver::Modulo   then [".modulo"] + walk_operators(node.receiver,
                                                                evaluator) + walk_operators(node.divisor, evaluator)
      when Struct
        node.members.flat_map { |member| walk_operators(node[member], evaluator) }
      else
        []
      end
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
