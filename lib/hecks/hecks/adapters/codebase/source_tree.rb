# frozen_string_literal: true

require_relative "tree"
require_relative "language"
require_relative "kernel_tables"
require_relative "conformance"
require_relative "regeneration"
require_relative "style"
require_relative "codemods"
require_relative "test_suite"
require_relative "corpus_tasks"

module Hecks
  module Adapters
    # The `SourceTree` port's adapter: everything Codebase does to the working tree of this
    # repository.
    #
    # It answers the one fact every Codebase request needs (`examine`: is the tree a hecks
    # checkout?), carries out an accepted request (`perform`), and answers Codebase's queries. Each
    # of them refuses "needs a hecks checkout" outside a checkout, so an installed gem never touches
    # an absent `rust/` or rewrites its own `lib/`, even when the journaled guard is bypassed.
    # `perform` finds the task family that carries an operation out; a family lives beside this
    # file and does the work with the existing generators, linters and tools.
    class SourceTree
      class << self
        # @return [#capture, nil] starts each child process; a `Shell` when nil. A spec replaces it
        #   so no gate has to run to test what is asked of it.
        attr_accessor :shell
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Reports whether the working tree is a hecks checkout.
      #
      # @param _held [Hash] the record, which holds nothing this needs
      # @return [Hash{Symbol => Hash}] `checkout:` whether hecks.gemspec stands beside lib/
      def examine(**_held)
        { checkout: { value: tree.checkout? } }
      end

      # Carries out the operation an accepted request names.
      #
      # @param held [Hash] the record: `operation` and every argument the request set
      # @return [Hash{Symbol => Hash}] `report:` what was found, or done
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when no family carries the operation out, or it refuses
      def perform(**held)
        tree.require_checkout!
        operation = plain(held[:operation])
        family = FAMILIES.find { |candidate| candidate::OPERATIONS.include?(operation) }
        raise ConsoleCapture::Failure, "no task carries out #{operation.inspect}" unless family

        args = held.except(:operation)
        { report: { value: family.call(operation, args, tree, shell: self.class.shell || Shell.new) } }
      end

      # @return [String] where every word of the language stands
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      def word_status(**)
        tree.require_checkout!
        Codebase::Language.word_status
      end

      # @param args [Hash] the query's arguments: `paths`, `only`, `json`, `top`
      # @return [String] the Ruby comment violations, as the linter reports them
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when the linter refuses its arguments
      def report_comments(**args)
        report("report_comments", args)
      end

      # @param args [Hash] the query's arguments: `paths`, `only`, `json`, `top`
      # @return [String] the Rust comment violations, as the linter reports them
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when the linter refuses its arguments
      def report_rust_comments(**args)
        report("report_rust_comments", args)
      end

      # @param args [Hash] the query's arguments: `group`, `groups`, `runtime_log`
      # @return [String] the spec files one group of a runtime-balanced split runs, one per line
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when the script refuses its arguments
      def shard_specs(**args)
        test_suite("shard_specs", args)
      end

      # @param args [Hash] the query's arguments: `exclude`, `tags`, `check`
      # @return [String] the spec files with an example the tag filter selects, one per line
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when the list is stale, or the script refuses its arguments
      def list_io_parallel_specs(**args)
        test_suite("list_io_parallel_specs", args)
      end

      # @return [String] the expected match results of the pattern cases, as JSON
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      def record_pattern_cases(**)
        test_suite("record_pattern_cases", {})
      end

      # @return [String] the feature and directory of every domain with a Rust feature
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      def rust_domains(**)
        corpus("rust_domains", {})
      end

      # @return [String] the directories regeneration walks, in the order it walks them
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      def regen_order(**)
        corpus("regen_order", {})
      end

      # @return [String] whether each generated Rust module is covered
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when a module is not covered
      def corpus_rust_coverage(**)
        corpus("corpus_rust_coverage", {})
      end

      # @param args [Hash] the query's arguments: `names`
      # @return [String] each IR construct's diff from its meta-domain
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      def ir_constructs(**args)
        corpus("ir_constructs", args)
      end

      # @param args [Hash] the query's arguments: `domains`, `meta`
      # @return [String] the rules declared more than once
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      def ir_duplicates(**args)
        corpus("ir_duplicates", args)
      end

      # @param args [Hash] the query's arguments: `name`, `field`
      # @return [String] which propagation touchpoints already show the field
      # @raise [Codebase::Tree::NeedsCheckout] when the tree is not a hecks checkout
      # @raise [ConsoleCapture::Failure] when the construct is not one
      def ir_impact(**args)
        corpus("ir_impact", args)
      end

      private

      def test_suite(operation, args)
        tree.require_checkout!
        plain_args = args.transform_values { |value| plain(value) }
        Codebase::TestSuite.report(operation, plain_args, tree, shell: self.class.shell)
      end

      def corpus(operation, args)
        tree.require_checkout!
        plain_args = args.transform_values { |value| plain(value) }
        Codebase::CorpusTasks.report(operation, plain_args, tree, shell: self.class.shell)
      end

      def report(operation, args)
        tree.require_checkout!
        plain_args = args.transform_values { |value| plain(value) }
        Codebase::Style.report(operation, plain_args, tree, shell: self.class.shell)
      end

      # The task families, each carrying out the operations it lists.
      FAMILIES = [Codebase::Language, Codebase::KernelTables, Codebase::Conformance, Codebase::Regeneration,
                  Codebase::Style, Codebase::Codemods, Codebase::TestSuite, Codebase::CorpusTasks].freeze
      private_constant :FAMILIES

      def tree = Codebase::Tree.new

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
