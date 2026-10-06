require_relative "../../bluebook/expression"

module Hecks
  module Runtime
    module DependencyPlanning
      # Collects the dotted paths a canonical expression reads, without evaluating it.
      # Used by Analyzer to classify rule dependencies.
      module ExpressionReads
        module_function

        # Paths by canonical text: parsing is a pure function of the text, and the analyzer asks
        # for the same rule text on every dispatch of a command. A text that fails to parse
        # raises before it is stored, so a failure is never cached. Written from dispatch
        # threads, so every access holds PATHS_LOCK; the cache is cleared when it reaches
        # PATHS_CACHE_LIMIT entries, so distinct texts cannot grow it without bound.
        # rubocop:disable-next Style/MutableConstant
        PATHS_CACHE = {}
        PATHS_LOCK = Mutex.new
        PATHS_CACHE_LIMIT = 4096
        private_constant :PATHS_CACHE, :PATHS_LOCK

        # Finds every dotted path a canonical expression reads.
        #
        # Walks the parsed nodes the evaluator uses; only Lookup nodes carry dependencies.
        #
        # @param canonical [String] the canonical expression text
        # @return [Array<String>] the dotted paths the expression reads (frozen)
        def paths(canonical)
          cached = PATHS_LOCK.synchronize { PATHS_CACHE[canonical] }
          return cached if cached

          found = collect(Bluebook::Expression::Evaluator.parse(canonical), Set.new).freeze
          PATHS_LOCK.synchronize do
            PATHS_CACHE.clear if PATHS_CACHE.size >= PATHS_CACHE_LIMIT && !PATHS_CACHE.key?(canonical)
            PATHS_CACHE[canonical] ||= found
          end
        end

        # Walks one parsed node, skipping names bound by an enclosing block predicate.
        def collect(node, bound_names)
          case node
          when Bluebook::Expression::Resolver::Lookup
            collect_lookup(node, bound_names)
          when Bluebook::Expression::Resolver::BlockPredicate
            collect_block(node, bound_names)
          when Struct, Array
            collect_children(node, bound_names)
          else
            []
          end
        end

        # A block predicate's receiver reads under the outer names; its predicate also under the
        # parameter the block binds.
        def collect_block(node, bound_names)
          collect(node.receiver, bound_names) +
            collect(node.predicate, bound_names | [node.param.to_s])
        end

        def collect_children(node, bound_names)
          children = node.is_a?(Struct) ? node.each_pair.map { |_name, value| value } : node
          children.flat_map { |value| collect(value, bound_names) }
        end

        # The path a lookup reads, unless its root is a name an enclosing block bound.
        def collect_lookup(node, bound_names)
          root = node.path.to_s.split(".", 2).first
          bound_names.include?(root) ? [] : [node.path.to_s]
        end
      end
    end
  end
end
