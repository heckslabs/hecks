require "hecks"

# Answers `Prism.canonical` from memory for a block whose file the adapter has already parsed.
#
# Every `given`, invariant and identified_by block in a bluebook asks for its own canonical source,
# and each ask stats the file (`File.readable?`) before looking up the tree it already holds.
# Booting
# and building domains in specs does that hundreds of thousands of times, so it is the single
# hottest call in a plain run. Here a block is looked up by its tree and line once; `forget` and
# `forget_all` drop the tree, so an edited-and-reloaded file is read again. Specs only.
module PrismSourceMemo
  ANSWERS = {}.compare_by_identity
  MISSING = Object.new.freeze

  # Prepended to Hecks::Adapters::Prism's singleton class.
  module Memoized
    def canonical(block)
      file, line = block.source_location
      tree = file && Hecks::Adapters::Prism::TREES[file]
      return super unless tree

      by_line = PrismSourceMemo::ANSWERS[tree] ||= {}
      answer = by_line.fetch(line, PrismSourceMemo::MISSING)
      return answer unless answer.equal?(PrismSourceMemo::MISSING)

      by_line[line] = super
    end
  end
end

Hecks::Adapters::Prism.singleton_class.prepend(PrismSourceMemo::Memoized)
