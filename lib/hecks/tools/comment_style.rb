# frozen_string_literal: true

require "English"
require "json"
require "optparse"
require "pathname"
require "ripper"
require_relative "../tools"
require_relative "comment_style/vocabulary"
require_relative "comment_style/patterns"
require_relative "comment_style/dictionary"
require_relative "comment_style/baseline"
require_relative "comment_style/source_file"
require_relative "comment_style/run"
require_relative "comment_style/cli"

module Hecks
  module Tools
    # Checks a set of Ruby files against docs/COMMENT_STYLE_GUIDE.md and,
    # for the mechanical categories, rewrites them to comply.
    module CommentStyle
      MAX_LINE = 100
      LONG_CLASS_DOC = 25
      MAX_HEADING_WORDS = 6

      # A run of comment lines longer than this is a `long_block`, unless the baseline holds it.
      # ADR 0075 ticket 01 sets this value, amending ADR 0069's provisional 50.
      MAX_BLOCK = 12

      # Longest anchor kept in a block's baseline key.
      MAX_ANCHOR = 80

      CATEGORIES = {
        "undocumented_method"    => "public method has no doc comment",
        "missing_param"          => "doc comment lacks @param for a parameter",
        "missing_return"         => "doc comment lacks @return",
        "missing_raise"          => "method raises but doc comment lacks @raise",
        "undocumented_class"     => "class or module has no doc comment",
        "unstructured_class_doc" => "long class doc has no ## section headers",
        "missing_summary"        => "doc comment has tags but no lead sentence",
        "all_caps"               => "all-caps emphasis",
        "long_bold"              => "bold heading over #{MAX_HEADING_WORDS} words reads as shouting",
        "bare_constant"          => "capitalised word names something in this file's code: backtick or lowercase it",
        "unknown_capitals"       => "capitalised token is not an English word: backtick it or list it as an acronym",
        "design_history"         => "narrates design history instead of citing an ADR",
        "long_line"              => "comment line exceeds #{MAX_LINE} characters",
        "long_block"             => "comment block exceeds #{MAX_BLOCK} lines and is new or has grown past its baseline"
      }.freeze

      FIXABLE = %w[all_caps long_bold long_line].freeze

      Violation = Struct.new(:path, :line, :category, :message)
      MethodDef = Struct.new(:name, :line, :params, :visibility, :raises, :block_param, :type_fqn)
      TypeDef = Struct.new(:fqn, :line, :namespace_only)
      Comment = Struct.new(:line, :col, :text, :full_line)
      Block = Struct.new(:line, :lines, :key)

      # Bare class/module names on Hecks's documented public surface (ADR 0075 ticket 01):
      # an operator or a client calls these directly. The DSL itself (`aggregate`,
      # `command`, `query`, ...) is invoked through the `Hecks.bluebook` block, not by
      # naming a builder class, so its builder classes stay off this list.
      #
      # A method's structural checks (tags, `undocumented_method`) apply only when its
      # innermost enclosing type's own name is here; everything else is internal and
      # needs no doc unless it carries a real why.
      PUBLIC_SURFACE = Set["Storehouse"].freeze

      # The hashes that open a comment and the space after them.
      COMMENT_MARKER = /\A#+\s*/
      # A comment line with nothing after its hashes: a paragraph break.
      EMPTY_COMMENT = /\A#+\s*\z/
      # A shouted contraction or possessive ending: `'S`, `'LL`, `'RE`.
      SHOUTED_SUFFIX = /'[A-Z]{1,2}\z/
      # A Roman numeral, which stays in capitals.
      ROMAN_NUMERAL = /\A[IVX]+\z/
      # Sentence punctuation, any closing quotes or brackets, then the space before a new word.
      SENTENCE_BREAK = /[.!?]["')\]]*\s+\z/
      # Sentence punctuation and any closing quotes or brackets, ending the text.
      SENTENCE_END = /[.!?]["')\]]*\z/
      # A list marker alone before the word: a bullet, a rule, or a number.
      LIST_MARKER = /\A\s*(?:[-*•]|─+|\d+[.)])\s+\z/
      # A whole word of two or more capitals.
      SHOUTED_WORD = /\b[A-Z]{2,}\b/
      # Any lowercase letter.
      LOWERCASE = /[a-z]/
      # A backtick code span.
      CODE_SPAN = /`[^`]*`/
      # A `class` or `module` line, capturing the type's own name.
      TYPE_DEFINITION = /^\s*(?:class|module)\s+([A-Z]\w*)/

      extend Cli

      # Class and module names defined under `lib/`, keyed by their shouted form.
      def self.class_names
        @class_names ||= Dir["lib/**/*.rb"].each_with_object({}) do |file, names|
          File.read(file).scan(TYPE_DEFINITION) do |(name)|
            names[name.upcase] ||= name if name.match?(LOWERCASE)
          end
        end
      end

      # Lexes `source` and drops every comment and whitespace token.
      def self.code_tokens(source)
        Ripper.lex(source).reject { |token| CODE_NOISE.include?(token[1]) }.map { |token| token[2] }
      end

      def self.public_surface
        PUBLIC_SURFACE
      end
    end
  end
end
