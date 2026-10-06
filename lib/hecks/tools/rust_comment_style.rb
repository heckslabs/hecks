# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../tools"
require_relative "comment_style"
require_relative "rust_comment_style/tokenizer"
require_relative "rust_comment_style/source_file"
require_relative "rust_comment_style/run"

module Hecks
  module Tools
    # Checks Rust files against docs/COMMENT_STYLE_GUIDE_RUST.md, sharing its
    # prose vocabulary with `CommentStyle`, the Ruby-side linter.
    module RustCommentStyle
      MAX_LINE = CommentStyle::MAX_LINE
      MAX_HEADING_WORDS = CommentStyle::MAX_HEADING_WORDS

      CATEGORIES = {
        "missing_doc"        => "public item has no /// doc comment",
        "missing_module_doc" => "file has no //! module doc at its top",
        "all_caps"           => "all-caps emphasis",
        "long_bold"          => "bold heading over #{MAX_HEADING_WORDS} words reads as shouting",
        "bare_constant"      => "capitalised word names a const/static in this file: backtick or lowercase it",
        "unknown_capitals"   => "capitalised token is not an English word: backtick it or list it as an acronym",
        "design_history"     => "narrates design history instead of citing an ADR",
        "long_line"          => "comment line exceeds #{MAX_LINE} characters"
      }.freeze

      FIXABLE = %w[all_caps long_bold long_line].freeze

      MARKER = %r{\A/{2,3}!?\s*}
      DOC_LINE = %r{\A\s*(?:///(?!/)|//!)}

      # `// TMPL:name BEGIN`/`END` sentinels are parsed verbatim by
      # `rust/codegen/src/exemplar.rs`; every prose rule skips them outright.
      TMPL_MARKER = /\bTMPL:\S+\s+(?:BEGIN|END)\b/i
      MOD_DOC_LINE = %r{\A\s*//!}
      ATTR_LINE = /\A\s*#\[/
      BOLD_HEADING = %r{\A(/{2,3}!?\s*(?:[-*]\s+)?)\*\*([^*]+)\*\*}
      HEADING_END = CommentStyle::HEADING_END
      GAP = CommentStyle::GAP
      FILLER = CommentStyle::FILLER

      # `main` is a pub fn entry point, not an API surface to document.
      SELF_EVIDENT_FNS = %w[main].to_set.freeze

      # Rust-specific acronyms beyond the Ruby linter's list.
      RUST_ACRONYMS = %w[EOF RAII RHS SQS DLQ JIT LSP NFA DFA CR].to_set.freeze

      RUST_PROPER_NOUNS = {}.freeze

      RUST_EXTRA_WORDS = %w[
        cardinality routability prepend safer diff diffed stats earliest unbracketed
        variadic ordering orderings reenter dereference entrypoint wildcard
        sandbox sandboxed unsandboxed expr enum codegen serialise serialises
        preprocessing backslash
      ].freeze

      PUB_ITEM = /
        \A\s*pub(?:\([^)]*\))?\s+
        (?:async\s+|unsafe\s+|extern\s+"[^"]*"\s+|const\s+)*
        (fn|struct|enum|trait|mod|type)\s+
        ([A-Za-z_][A-Za-z0-9_]*)
      /x

      Violation = Struct.new(:path, :line, :category, :message)
      Comment = Struct.new(:line, :col, :text, :full_line)

      # Folds Rust jargon into the shared word list so `Dictionary.english?`
      # already covers these words' plurals, gerunds, and past tense too.
      CommentStyle::Dictionary.words&.merge(RUST_EXTRA_WORDS)

      # Builds the CLI's option parser, filling `options` as flags are seen.
      def self.option_parser(options)
        OptionParser.new do |opts|
          opts.banner = "Usage: hecks check_rust_comments [--report|--check|--fix] [--only a,b] PATH..."
          opts.on("--report", "summary tables (default)") { options[:mode] = :report }
          opts.on("--check", "list every violation, exit 1 if any") { options[:mode] = :check }
          opts.on("--fix", "rewrite fixable categories: #{FIXABLE.join(", ")}") { options[:mode] = :fix }
          filter_options(opts, options)
        end
      end

      # Registers the flags that narrow or reshape the output.
      def self.filter_options(opts, options)
        opts.on("--only LIST", Array, "limit to: #{CATEGORIES.keys.join(", ")}") { |list| options[:only] = list }
        opts.on("--json", "machine-readable output") { options[:json] = true }
        opts.on("--top N", Integer, "rows in the worst-files table") { |n| options[:top] = n }
      end

      # Prints `--report`, `--check`, or `--json` output for a finished run.
      def self.render(run, options)
        found = run.violations
        print_run(run, found, options)
        options[:mode] == :check && found.any? ? 1 : 0
      end

      # Prints the run in the shape the options ask for.
      def self.print_run(run, found, options)
        if options[:json]
          puts JSON.pretty_generate(found.map(&:to_h))
        elsif options[:mode] == :check
          found.each { |v| puts "#{v.path}:#{v.line}: [#{v.category}] #{v.message}" }
        else
          puts run.report(top: options[:top])
        end
      end

      # The CLI entry point: parses `argv` and runs the requested mode.
      #
      # Paths after a `--` are never read as flags, and a path that does not exist is refused.
      def self.main(argv, **)
        options, paths = parse_arguments(argv)
        run = Run.new(paths, only: options[:only])
        case options[:mode]
        when :fix then puts("rewrote #{run.fix!} files") || 0
        else render(run, options)
        end
      end

      # Parses `argv`, refusing an unknown category, a missing path, or no path at all.
      #
      # @return [Array(Hash, Array<String>)] the options and the paths
      def self.parse_arguments(argv)
        options = { mode: :report, top: 20 }
        parser = option_parser(options)
        paths = parser.parse(argv)
        unknown = Array(options[:only]) - CATEGORIES.keys
        abort "unknown categories: #{unknown.join(", ")}" unless unknown.empty?
        abort parser.help if paths.empty?
        refuse_missing_paths(paths)
        [options, paths]
      end

      # Refuses a path that does not exist.
      def self.refuse_missing_paths(paths)
        missing = paths.reject { |path| File.exist?(path) }
        abort "no such path: #{missing.join(", ")}" unless missing.empty?
      end
    end
  end
end
