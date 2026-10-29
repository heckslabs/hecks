# frozen_string_literal: true

module Hecks
  module Adapters
    class SourceTree
      # The `SourceTree` queries that read the corpus of domains: which have Rust, the order regeneration
      # walks them in, and what the IR and its propagation touchpoints say. Each is answered through
      # `corpus`, which the includer provides.
      module CorpusQueries
        # @return [Hash] `text:` the feature and directory of every domain with a Rust feature
        # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
        def rust_domains(**)
          { text: corpus("rust_domains", {}) }
        end

        # @return [Hash] `text:` the directories regeneration walks, in the order it walks them
        # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
        def regen_order(**)
          { text: corpus("regen_order", {}) }
        end

        # @return [Hash] `text:` whether each generated Rust module is covered
        # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
        # @raise [ConsoleCapture::Failure] when a module is not covered
        def corpus_rust_coverage(**)
          { text: corpus("corpus_rust_coverage", {}) }
        end

        # @param args [Hash] the query's arguments: `names`
        # @return [Hash] `text:` each IR construct's diff from its meta-domain
        # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
        def ir_constructs(**args)
          { text: corpus("ir_constructs", args) }
        end

        # @param args [Hash] the query's arguments: `domains`, `meta`
        # @return [Hash] `text:` the rules declared more than once
        # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
        def ir_duplicates(**args)
          { text: corpus("ir_duplicates", args) }
        end

        # @param args [Hash] the query's arguments: `name`, `field`
        # @return [Hash] `text:` which propagation touchpoints already show the field
        # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
        # @raise [ConsoleCapture::Failure] when the construct is not one
        def ir_impact(**args)
          { text: corpus("ir_impact", args) }
        end
      end
    end
  end
end
