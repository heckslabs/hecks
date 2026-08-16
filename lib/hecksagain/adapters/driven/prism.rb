require "prism"
require_relative "../../bluebook/expression/canonical_form"

module Hecksagain
  module Adapters
    class NotExtractable < StandardError; end

    module Prism
      TREES = {}

      module_function

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

      def block_node_at(file, line)
        found = nil
        walk(tree_for(file)) do |node|
          next unless node.is_a?(::Prism::BlockNode)
          next unless node.location.start_line == line

          found ||= node
        end
        found
      end

      def tree_for(file)
        # ::Prism.parse_file(file) reads the file itself, at the C
        # extension level — bypassing Ruby's own File/IO layer entirely.
        # That's invisible to anything that virtualizes the filesystem at
        # the Ruby level instead of the OS level (e.g. tebako's memfs,
        # used to press a hecksagain-based app into a single executable —
        # see domain/README.md's "Deploying" section in lifeadelics for
        # why that matters). ::Prism.parse(File.read(file)) parses the
        # exact same bytes, just read through Ruby's File.read first,
        # which those tools do intercept.
        TREES[file] ||= ::Prism.parse(File.read(file)).value
      end

      # `TREES` caches for the life of the PROCESS, keyed by path, with
      # no staleness check — correct for every ordinary caller (a file
      # loads once per process: one `bin/ir` run, one rspec worker,
      # never edited out from under it), but WRONG for anything that
      # legitimately reloads an edited file in-process: a stale cached
      # tree reports a `given`/`ensures` block at its OLD line number,
      # which no longer matches the freshly re-executed file's own
      # `block.source_location` — surfacing as "did not survive
      # extraction" on a perfectly valid file. Found for real building
      # `Hecksagain::Codemod` (lib/hecksagain/codemod.rb), which used to
      # reach into `TREES.clear` directly — a private implementation
      # detail poked from outside. `forget`/`forget_all` are the real
      # API so nothing else that reloads an edited file in-process has
      # to know `TREES` exists at all.
      def forget(file) = TREES.delete(file)

      def forget_all = TREES.clear

      def walk(node, &visit)
        return unless node.is_a?(::Prism::Node)

        visit.call(node)
        node.compact_child_nodes.each { |child| walk(child, &visit) }
      end

      def canonicalise(source)
        Bluebook::Expression::CanonicalForm.apply(source)
      end
    end
  end
end
