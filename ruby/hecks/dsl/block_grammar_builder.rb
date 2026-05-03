# Hecks::DSL::BlockGrammarBuilder
#
# DSL builder for the +block_grammar+ keyword (i218). Captures an
# ordered list of `block "<keyword>", parser: :<parser_name>` pairs
# declaring how the parser routes top-level keywords to typed block
# parsers, and builds a +BluebookModel::Behavior::BlockGrammar+ IR node.
#
#   block_grammar "Bluebook" do
#     block "aggregate",        parser: :parse_aggregate
#     block "policy",           parser: :parse_policy
#     block "process_manager",  parser: :parse_process_manager
#     block "cadence",          parser: :parse_cadence
#     block "section",          parser: :parse_section
#   end
#
# Validation (raised as +ArgumentError+ at +build+):
#
# 1. at least one +block+ must be declared
# 2. each block's keyword must be a non-empty String
# 3. each block's parser must be a non-empty Symbol/String
# 4. keywords must be unique within the grammar
#
module Hecks
  module DSL
    class BlockGrammarBuilder
      Behavior = BluebookModel::Behavior

      include Describable

      # @param name [String] grammar name (e.g. "Bluebook")
      def initialize(name)
        @name = name
        @blocks = []
      end

      # Declare one keyword -> parser_name binding. Order matters : the
      # first matching keyword claims a line.
      #
      # @param keyword [String] the line-leading keyword (e.g. "aggregate")
      # @param parser [Symbol,String] the named parser function
      def block(keyword, parser:)
        @blocks << Behavior::BlockGrammar::Block.new(
          keyword: keyword.to_s,
          parser_name: parser.to_sym
        )
      end

      def build
        validate!
        Behavior::BlockGrammar.new(
          name: @name,
          blocks: @blocks,
          description: @description
        )
      end

      private

      def validate!
        if @blocks.empty?
          raise ArgumentError,
                "block_grammar '#{@name}' must declare at least one `block`"
        end
        seen = {}
        @blocks.each do |b|
          if b.keyword.to_s.empty?
            raise ArgumentError,
                  "block_grammar '#{@name}' has a block with empty keyword"
          end
          if b.parser_name.to_s.empty?
            raise ArgumentError,
                  "block_grammar '#{@name}' block '#{b.keyword}' has empty parser"
          end
          if seen[b.keyword]
            raise ArgumentError,
                  "block_grammar '#{@name}' has duplicate keyword '#{b.keyword}'"
          end
          seen[b.keyword] = true
        end
      end
    end
  end
end
