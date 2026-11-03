require_relative "parser_table"

module Hecks
  module Projections
    # The Ruby file the cache digests read, projected from the `CacheInput` rows of the Syntax
    # aggregate. Each row becomes one member of `MetaValidator::CacheInput::MEMBERS`, so no
    # cache keeps its own list of files.
    module CacheInputFile
      # The text before the members. Plain data with no requires, because the verdict cache
      # reads it before the grammar registry is built.
      HEADER = <<~RUBY.freeze
        # Generated - projected from the CacheInput rows of the Syntax aggregate in
        # lib/hecks/language/bluebook/syntax.bluebook.
        #
        # Do not edit. Run `hecks project_parser_table`; the codegen drift job diffs this file.
        #
        # Plain data, no requires: the verdict cache and the syntax table cache read it before the
        # grammar registry is built. A file enters a digest when a `digest: true` glob matches it and
        # no `digest: false` glob does. Globs are relative to lib/.

        module Hecks
          module Bluebook
            module MetaValidator
              # The path classes a cache digest reads, declared once in the grammar.
              module CacheInput
                # Every member: its name, whether it enters the digest, and the glob it reads.
                MEMBERS = [
      RUBY

      # The text after the members.
      FOOTER = <<~RUBY.freeze
                ].freeze
              end
            end
          end
        end
      RUBY

      # Where the file lives, relative to the checkout.
      RELATIVE_PATH = "lib/hecks/bluebook/meta_validator/cache_input.rb".freeze

      module_function

      # The two files `parser_table` writes: the Rust keyword table and this Ruby file.
      #
      # @param root [String] the checkout
      # @param parser_table [String] the rendered Rust keyword table
      # @param bluebook [Bluebook::Declaration] the bluebook both files are projected from
      # @return [Hash{String => String}] the text each absolute path should hold
      def with_parser_table(root, parser_table, bluebook)
        {
          File.join(root, "rust/parser/src/keywords.rs") => parser_table,
          File.join(root, RELATIVE_PATH)                 => render(bluebook)
        }
      end

      # Renders the Ruby file the cache keys read.
      #
      # @param bluebook [Bluebook::Declaration] the bluebook to read the CacheInput rows from
      # @return [String] the rendered Ruby source
      def render(bluebook)
        members = ParserTable.rows(bluebook, "CacheInput").map { |row| member(row) }
        "#{HEADER}#{members.join(",\n")}\n#{FOOTER}"
      end

      # Renders one `CacheInput::MEMBERS` entry, without its separating comma.
      #
      # @param row [Hash{Symbol => String}] one CacheInput row, with `name`, `digest` and `glob`
      # @return [String] one `{ name:, digest:, glob: }` entry
      def member(row)
        "          { name: #{row[:name].inspect}, digest: #{row[:digest] == "yes"}, glob: #{row[:glob].inspect} }"
      end
    end
  end
end
