# frozen_string_literal: true

require "ripper"
require_relative "../../tools"
require_relative "long_blocks"
require_relative "masking"
require_relative "caps_words"
require_relative "text_checks"
require_relative "fixing"
require_relative "structure_checks"

module Hecks
  module Tools
    module CommentStyle
      # One parsed source file and the violations found in it.
      class SourceFile
        include LongBlocks
        include Masking
        include CapsWords
        include TextChecks
        include Fixing
        include StructureChecks

        attr_reader :path, :lines, :comments

        def initialize(path, source = nil)
          @path = path
          @source = source || File.read(path)
          @lines = @source.lines
          @comments = lex_comments
          @by_line = @comments.to_h { |c| [c.line, c] }
          @open_spans = open_spans
          @constants = code_words
        end

        # Finds every place this file departs from the style guide.
        def violations(only: nil, baseline: {})
          return [] if generated?

          found = text_violations + (test_file? ? [] : structure_violations) + long_block_violations(baseline)
          found = found.select { |v| only.include?(v.category) } if only
          found.sort_by { |v| [v.line, v.category] }
        end

        # Rewrites the mechanical categories; raises rather than write a change that alters code.
        def fixed(only: nil)
          return @source if generated?

          wanted = (only || FIXABLE) & FIXABLE
          output = @lines.map.with_index(1) { |line, number| fix_line(line, number, wanted) }.join
          return @source if output == @source

          unchanged = CommentStyle.code_tokens(@source) == CommentStyle.code_tokens(output)
          raise "#{path}: fix would change code, refusing" unless unchanged

          output
        end

        # Parses this file's structure once and caches it.
        def types
          test_file? || generated? ? [] : structure.last
        end

        # A generated file's comments belong to its generator, and its
        # `GENERATED ... DO NOT EDIT` banner is a convention tools recognise.
        def generated?
          @lines.first(8).join.match?(/\bgenerated\b.*?\bdo not edit\b/im)
        end

        # Helpers defined inside a spec are test scaffolding, not API, so the
        # doc-tag categories skip them. The prose categories still apply.
        def test_file?
          path.end_with?("_spec.rb")
        end

        # A `class`/`module` is documented only if a comment block sits directly above it.
        def documented?(type)
          !doc_above(type.line).empty?
        end

        private

        def lex_comments
          Ripper.lex(@source).filter_map do |(line, col), type, text, _|
            next unless type == :on_comment

            prefix = @lines[line - 1].byteslice(0, col)
            Comment.new(line, col, text.chomp, prefix.strip.empty?)
          end
        end

        # All-caps names in this file's code: constants, heredoc delimiters, and
        # strings that are nothing but one such name (`ENV["PATH"]`).
        def code_words
          Ripper.lex(@source).each_with_object(Set.new) do |(_, type, text, _), words|
            case type
            when :on_const, :on_tstring_content then words << text if text.match?(/\A[A-Z][A-Z0-9_]+\z/)
            when :on_heredoc_beg, :on_heredoc_end then words.merge(text.scan(/[A-Z][A-Z0-9_]+/))
            end
          end
        end
      end
    end
  end
end
