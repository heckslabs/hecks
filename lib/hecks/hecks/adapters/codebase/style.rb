# frozen_string_literal: true

require "json"
require_relative "tree"
require_relative "ruby_child"
require "hecks/canonical_json"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `StyleRun` asks of the working tree: keeping comments to the style guides
      # (Ruby's `docs/COMMENT_STYLE_GUIDE.md`, Rust's `docs/COMMENT_STYLE_GUIDE_RUST.md`), and
      # writing a JSON document with its keys in order.
      #
      # The linters are `Hecks::Tools::CommentStyle` and `Hecks::Tools::RustCommentStyle`, which own
      # their options, so each ask runs one in this process from the checkout's root. A check
      # that finds violations refuses with the list. A fix rewrites files, so unconfirmed it lists
      # what it would rewrite (the fixable categories only) and writes nothing.
      module Style
        # Every operation this family carries out.
        OPERATIONS = %w[check_comments fix_comments write_comment_baseline check_comments_unchanged
                        check_rust_comments fix_rust_comments canonicalise].freeze

        # The categories a fix rewrites, in both linters.
        FIXABLE = "all_caps,long_bold,long_line"

        # Where the long-block baseline is written from, and what a `--code-unchanged` compares.
        BASELINE_PATHS = ["lib/hecks"].freeze

        # The paths a code-unchanged check looks at when none are named.
        UNCHANGED_PATHS = ["lib"].freeze

        # The linter each operation runs.
        SCRIPTS = { "check_rust_comments"  => "standardize_comments_rust",
                    "fix_rust_comments"    => "standardize_comments_rust",
                    "report_rust_comments" => "standardize_comments_rust" }.freeze

        module_function

        # Carries out one operation.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `StyleRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused: the linters run in this process
        # @return [String] what the linter printed, or the file in order
        # @raise [ConsoleCapture::Failure] when a check finds a violation, or the linter or file is
        #   refused
        def call(operation, held, tree, shell: nil)
          args = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          return canonical(args, tree) if operation == "canonicalise"

          child = RubyChild.new(tree, shell: shell)
          case operation
          when "check_comments", "check_rust_comments" then check(operation, args, child)
          when "fix_comments", "fix_rust_comments" then fix(operation, args, child)
          when "write_comment_baseline" then baseline(args, child)
          else unchanged(args, child)
          end
        end

        # A pure read: the linter's summary, its violations, or its JSON.
        #
        # @param operation [String] `report_comments` or `report_rust_comments`
        # @param args [Hash] the query's plain arguments: `paths`, `only`, `json`, `top`
        # @param tree [Tree] the checkout
        # @param shell [#capture, nil] unused: the linters run in this process
        # @return [String] the linter's report
        # @raise [ConsoleCapture::Failure] when the linter refuses its arguments
        def report(operation, args, tree, shell: nil)
          flags = ["--report", *only_flags(args)]
          flags << "--json" if args[:json]
          flags.push("--top", args[:top].to_s) if args[:top]
          RubyChild.new(tree, shell: shell).answer(script_of(operation), *flags, *paths_of(args))
        end

        # @param args [Hash] the record's plain fields
        # @param tree [Tree] the checkout
        # @return [String] the JSON document at `file`, every object's keys in order
        # @raise [ConsoleCapture::Failure] when the file cannot be read or is not JSON
        def canonical(args, tree)
          path = File.expand_path(args[:file].to_s)
          CanonicalJson.pretty(File.read(path))
        rescue Errno::ENOENT
          raise ConsoleCapture::Failure, "no such file #{path} (relative to #{Dir.pwd}, tree #{tree.root})"
        rescue JSON::ParserError => e
          raise ConsoleCapture::Failure, "#{path} is not JSON: #{e.message.lines.first.strip}"
        end

        # @param operation [String] `check_comments` or `check_rust_comments`
        # @param args [Hash] the record's plain fields
        # @param child [RubyChild] the linter's runner
        # @return [String] the linter's clean verdict
        # @raise [ConsoleCapture::Failure] with every violation, when there is one
        def check(operation, args, child)
          answer = child.answer(script_of(operation), "--check", *only_flags(args), *paths_of(args))
          answer.empty? ? "no comment violations" : answer
        end

        # @param operation [String] `fix_comments` or `fix_rust_comments`
        # @param args [Hash] the record's plain fields
        # @param child [RubyChild] the linter's runner
        # @return [String] the files rewritten, or (unconfirmed) the violations a fix would rewrite
        # @raise [ConsoleCapture::Failure] when the linter refuses its arguments
        def fix(operation, args, child)
          script = script_of(operation)
          return child.answer(script, "--fix", *only_flags(args), *paths_of(args)) if args[:confirm] == true

          found = child.capture(script, "--check", "--only", FIXABLE, *paths_of(args)).out.strip
          return "dry run: nothing a fix would rewrite" if found.empty?

          "dry run, #{found.lines.size} violations a fix would rewrite (add --confirm to rewrite):\n#{found}"
        end

        # @param args [Hash] the record's plain fields
        # @param child [RubyChild] the linter's runner
        # @return [String] what the baseline recorded, or (unconfirmed) the blocks it would record
        def baseline(args, child)
          paths = args[:paths] ? paths_of(args) : BASELINE_PATHS
          return child.answer("standardize_comments", "--write-baseline", *paths) if args[:confirm] == true

          found = child.capture("standardize_comments", "--check", "--only", "long_block", *paths).out.strip
          return "dry run: no block would be newly tolerated" if found.empty?

          "dry run, #{found.lines.size} blocks would be recorded as tolerated (add --confirm):\n#{found}"
        end

        # @param args [Hash] the record's plain fields: `ref`, and `paths` (`lib` when absent)
        # @param child [RubyChild] the linter's runner
        # @return [String] "code unchanged"
        # @raise [ConsoleCapture::Failure] naming each file whose code differs from the ref
        def unchanged(args, child)
          paths = args[:paths] ? paths_of(args) : UNCHANGED_PATHS
          child.answer("standardize_comments", "--code-unchanged", args[:ref].to_s, *paths)
        end

        # @param operation [String] an operation
        # @return [String] the linter it runs
        def script_of(operation) = SCRIPTS.fetch(operation, "standardize_comments")

        # @param args [Hash] the record's plain fields
        # @return [Array<String>] `--only <list>` when categories are named
        def only_flags(args) = args[:only] ? ["--only", args[:only].to_s] : []

        # @param args [Hash] the record's plain fields
        # @return [Array<String>] the paths, from a comma-separated list
        def paths_of(args) = args[:paths].to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
