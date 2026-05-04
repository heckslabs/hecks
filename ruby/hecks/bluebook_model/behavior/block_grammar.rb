# Hecks::BluebookModel::Behavior::BlockGrammar
#
# IR node for the +block_grammar+ DSL keyword (i218). A block grammar
# declares the keyword routing for a parser : an ordered list of
# (keyword -> parser_name) pairs, each saying "lines that start with
# this keyword should be parsed by this named parser function".
#
# Replaces the hardcoded if-chain in rust/src/parser.rs that today
# dispatches `aggregate` / `policy` / `process_manager` / `cadence` /
# `section` etc. by string-prefix match. The Rust parser becomes a
# thin loop walking a registry built from this IR.
#
#   block_grammar "Bluebook" do
#     block "aggregate",        parser: :parse_aggregate
#     block "policy",           parser: :parse_policy
#     block "process_manager",  parser: :parse_process_manager
#     block "cadence",          parser: :parse_cadence
#     block "section",          parser: :parse_section
#   end
#
# The order of `block` declarations is the priority order : the first
# keyword whose prefix matches a line claims it. Authors can shadow a
# parent keyword by listing a more-specific keyword first.
#
module Hecks
  module BluebookModel
    module Behavior
      class BlockGrammar
        # One keyword -> parser_name binding inside a grammar.
        Block = Struct.new(:keyword, :parser_name, keyword_init: true) do
          def initialize(*)
            super
            self.keyword = keyword.to_s
            self.parser_name = parser_name.to_sym
          end
        end

        attr_reader :name, :blocks, :description

        # @param name [String] grammar name (e.g. "Bluebook")
        # @param blocks [Array<Block>] keyword/parser pairs in priority order
        # @param description [String, nil] optional description
        def initialize(name:, blocks:, description: nil)
          @name = name.to_s
          @blocks = blocks
          @description = description
        end
      end
    end
  end
end
