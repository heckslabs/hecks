module Hecks
  module Generators
    module Domain
      class AggregateGenerator < Hecks::Generator
        # Hecks::Generators::Domain::AggregateGenerator::InvariantGeneration
        #
        # Mixin that generates the +check_invariants!+ method for aggregate classes.
        # Converts DSL invariant blocks into runtime proc-based checks that raise
        # +InvariantError+ when violated. If no invariants are defined, generates
        # a no-op method. Part of Generators::Domain, mixed into AggregateGenerator.
        #
        # == Usage
        #
        #   class AggregateGenerator
        #     include InvariantGeneration
        #   end
        #
        module InvariantGeneration
          private

          # Generates lines for the +check_invariants!+ method.
          #
          # When invariants are present, each invariant produces a line that
          # evaluates its block via +instance_eval+ and raises +InvariantError+
          # with the invariant's message if the block returns falsy.
          #
          # When no invariants are defined, returns a single-line no-op method.
          #
          # @return [Array<String>] lines of Ruby source code for the check_invariants! method
          def invariant_lines
            if @aggregate.invariants.empty?
              return ["    def check_invariants!; end"]
            end

            lines = []
            lines << "    def check_invariants!"
            @aggregate.invariants.each do |inv|
              lines << "      raise InvariantError, #{inv.message.inspect} unless instance_eval(&#{source_from_block(inv.block)})"
            end
            lines << "    end"
            lines
          end

          # Converts an invariant's Ruby block into a proc source string.
          #
          # Uses +Hecks::Utils.block_source+ to extract the block's source code
          # and wraps it in a +proc { ... }+ literal.
          #
          # @param block [Proc] the invariant's condition block from the DSL
          # @return [String] a proc literal string (e.g., 'proc { amount > 0 }')
          def source_from_block(block)
            "proc { #{Hecks::Utils.block_source(block)} }"
          end
        end
      end
    end
  end
end
