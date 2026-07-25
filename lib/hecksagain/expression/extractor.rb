# Extractor — real Ruby source in, canonical expression text out.
#
# The predicate a developer writes is ordinary Ruby and stays ordinary Ruby :
#
#   given("at most 10 toppings") { toppings.size < 10 }
#
# Ruby 3.3 ships Prism, so that source is parsed by Ruby's OWN parser — not by
# a hand-rolled reader, and not by a proxy object pretending to be a list. The
# block knows where it was written (source_location) ; Prism turns that file
# into a tree ; the block body at that position is the expression.
#
# The arrow only runs this way. Ruby is read to produce IR ; IR is never read
# to produce Ruby.
#
#   Extractor.canonical(block)  # => "toppings.size < 10"
require "prism"

module Hecksagain
  module Expression
    class NotExtractable < StandardError; end

    module Extractor
      # Parsed files, keyed by path — a bluebook holds many predicates and
      # re-parsing the file for each one would be silly.
      TREES = {}

      module_function

      # The canonical text of a block, or nil when it has no readable source
      # (an eval'd or C-defined block has no file to read).
      def canonical(block)
        body = body_source(block)
        body && canonicalise(body)
      end

      def body_source(block)
        file, line = block.source_location
        return nil unless file && File.readable?(file)

        node = block_node_at(file, line)
        node&.body&.slice
      end

      # The block written at this line. Prism gives every node its exact
      # location, so the match is positional rather than a guess from text.
      def block_node_at(file, line)
        found = nil
        walk(tree_for(file)) do |node|
          next unless node.is_a?(Prism::BlockNode)
          next unless node.location.start_line == line

          found ||= node
        end
        found
      end

      def tree_for(file)
        TREES[file] ||= Prism.parse_file(file).value
      end

      def walk(node, &visit)
        return unless node.is_a?(Prism::Node)

        visit.call(node)
        node.compact_child_nodes.each { |child| walk(child, &visit) }
      end

      # One meaning, one text. Two spellings of the same predicate would hash
      # differently, diff as a change when nothing changed, and read as two
      # distinct programs to anything that partially evaluates on the text.
      #
      # `.length` folds to `.size` because the interpreter floor treats them as
      # one operation — normalising here means the fold happens once, at
      # extraction, rather than in every target that has to evaluate it.
      def canonicalise(source)
        source.to_s
              .gsub(/\s+/, " ")
              .gsub(/\.length\b/, ".size")
              .strip
      end
    end
  end
end
