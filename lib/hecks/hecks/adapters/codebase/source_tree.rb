# frozen_string_literal: true

require_relative "tree"
require_relative "language"
require_relative "kernel_tables"
require_relative "conformance"

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

      private

      # The task families, each carrying out the operations it lists.
      FAMILIES = [Codebase::Language, Codebase::KernelTables, Codebase::Conformance].freeze
      private_constant :FAMILIES

      def tree = Codebase::Tree.new

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
