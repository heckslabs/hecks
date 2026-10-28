# frozen_string_literal: true

module Hecks
  module ProjectionFiles
    # The sentence-table projection: the phrases an author may write, as the Rust parser's table.
    # Extended onto `ProjectionFiles`.
    module SentenceTable
      # @param root [String] the checkout
      # @return [Result] `rust/parser/src/phrases.rs`, from the Sentence bluebook
      def phrase_table(root)
        require "hecks"
        text = Projector.call(:phrase_table, bluebook: Projections::PhraseTable.declaration)
        Result.new({ File.join(root, "rust/parser/src/phrases.rs") => text }, [])
      end
    end
  end
end
