require "monitor"
require "prism"
require_relative "../../bluebook/expression/canonical_form"

module Hecks
  module Adapters
    class NotExtractable < StandardError; end

    # Extracts a `given`/`ensures`/invariant block's own source text via
    # `prism`, canonicalised into readable, comparable text (era diffing, docs).
    module Prism
      # Not frozen — a real cache, keyed by file path and mutated by
      # #tree_for below (`TREES[file] ||= ...`) and #forget/#forget_all.
      # False positive for Style/MutableConstant.
      # rubocop:disable-next Style/MutableConstant
      TREES = {}

      # The first block node starting on each line, per parsed tree (by identity), built by one
      # walk of the tree the first time a block in its file is looked up. Dropped with its tree
      # by #forget/#forget_all.
      BLOCKS_BY_LINE = {}.compare_by_identity

      # Guards `TREES` and `BLOCKS_BY_LINE` together, so a parse or an index build never
      # interleaves with a `forget` that drops the same tree. Reentrant: `block_node_at`
      # calls `tree_for` under it.
      LOCK = Monitor.new

      module_function

      # Recovers a block's body as canonical source text.
      #
      # @param block [Proc] a block written in a bluebook file, such as a `given` predicate
      #   or an `identified_by` path
      # @return [String, nil] the block body's source, normalised by
      #   `Bluebook::Expression::CanonicalForm`; nil if `body_source` finds none
      def canonical(block)
        body = body_source(block)
        body && canonicalise(body)
      end

      # Reads a block's own body source text back out of the file it was defined in.
      #
      # @param block [Proc] the block to locate, via its own `source_location`
      # @return [String, nil] the block body's raw source; nil if the file cannot be read,
      #   or no block node starts on the block's own line
      def body_source(block)
        file, line = block.source_location
        return nil unless file && File.readable?(file)

        node = block_node_at(file, line)
        node&.body&.slice
      end

      # Finds the parsed block node starting on a given line of a file.
      #
      # @param file [String] the file path, parsed (and cached) through `tree_for`
      # @param line [Integer] the 1-based source line the block starts on
      # @return [Prism::BlockNode, nil] the first block node found starting on `line`, or nil
      #   if none does
      def block_node_at(file, line)
        LOCK.synchronize do
          tree = tree_for(file)
          BLOCKS_BY_LINE[tree] ||= blocks_by_line(tree)
          BLOCKS_BY_LINE[tree][line]
        end
      end

      # Indexes a tree's block nodes by the line they start on, keeping the first in walk order.
      #
      # @param tree [Prism::ProgramNode] a parsed file's root node
      # @return [Hash{Integer => Prism::BlockNode}] block node by 1-based start line
      def blocks_by_line(tree)
        index = {}
        walk(tree) do |node|
          next unless node.is_a?(::Prism::BlockNode)

          index[node.location.start_line] ||= node
        end
        index
      end

      # Parses a file with `prism`, caching the result for the life of the process.
      #
      # @param file [String] the file path to parse and cache under
      # @return [Prism::ProgramNode] the parsed syntax tree's root node
      def tree_for(file)
        # ::Prism.parse_file reads the file at the C-extension level, bypassing
        # Ruby's File/IO layer — invisible to tools that virtualize the filesystem
        # there (e.g. tebako's memfs). Read through File.read first so they intercept it.
        LOCK.synchronize { TREES[file] ||= ::Prism.parse(File.read(file)).value }
      end

      # Drops one file from the process-wide parse cache, for a caller (`Hecks::Codemod`)
      # that reloads an edited file in-process and needs the stale tree invalidated.
      #
      # @param file [String] the file path to drop from the cache
      # @return [Prism::ProgramNode, nil] the cached tree that was removed, or nil if
      #   nothing was cached for `file`
      def forget(file)
        LOCK.synchronize do
          tree = TREES.delete(file)
          BLOCKS_BY_LINE.delete(tree)
          tree
        end
      end

      # Drops every cached parse tree.
      #
      # @return [Hash] the now-empty cache
      def forget_all
        LOCK.synchronize do
          BLOCKS_BY_LINE.clear
          TREES.clear
        end
      end

      # Visits `node` and every descendant depth-first, calling `visit` on each.
      #
      # @param node [Prism::Node, Object] the node to walk; anything that is not a
      #   `Prism::Node` is a silent no-op
      # @yieldparam node [Prism::Node] each node visited, `node` itself first
      # @return [void]
      def walk(node, &visit)
        return unless node.is_a?(::Prism::Node)

        yield(node)
        node.compact_child_nodes.each { |child| walk(child, &visit) }
      end

      # Normalises raw source text into the framework's own canonical form.
      #
      # @param source [String] the raw source text to normalise
      # @return [String] the normalised text (whitespace collapsed, linked replacements
      #   applied)
      def canonicalise(source)
        Bluebook::Expression::CanonicalForm.apply(source)
      end
    end
  end
end
