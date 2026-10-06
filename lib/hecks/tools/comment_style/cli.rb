# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../tools"
require_relative "run"

module Hecks
  module Tools
    module CommentStyle
      # The command line of the Ruby comment linter, which `CommentStyle` extends itself with.
      module Cli
        # Builds the CLI's option parser, filling `options` as flags are seen.
        def option_parser(options)
          OptionParser.new do |opts|
            opts.banner = "Usage: hecks check_comments [--report|--check|--fix] [--only a,b] PATH..."
            mode_options(opts, options)
            filter_options(opts, options)
          end
        end

        # Prints `--report`, `--check`, or `--json` output for a finished run.
        def render(run, options)
          found = run.violations
          print_run(run, found, options)
          options[:mode] == :check && found.any? ? 1 : 0
        end

        # The CLI entry point: parses `argv` and runs the requested mode.
        #
        # Paths after a `--` are never read as flags, and a path that does not exist is refused.
        def main(argv, root: Baseline::ROOT)
          options, paths = parse_arguments(argv)
          baseline_path = Baseline.path_in(root)
          run = Run.new(paths, only: options[:only], baseline: Baseline.load(baseline_path))
          case options[:mode]
          when :fix then puts("rewrote #{run.fix!} files") || 0
          when :write_baseline then write_baseline(run, baseline_path)
          when :code_unchanged then report_code_changes(changed_since(run, options[:ref]))
          else render(run, options)
          end
        end

        # Rewrites the baseline file from the blocks over `MAX_BLOCK` lines that `run` finds.
        def write_baseline(run, path = Baseline::PATH)
          held = run.long_block_baseline
          Baseline.dump(held, path)
          puts "recorded #{held.values.sum(&:size)} blocks in #{held.size} files at #{path}"
          0
        end

        # The files `run` finds changed since `ref`, refusing a ref that names no commit.
        def changed_since(run, ref)
          run.code_changed_since(ref)
        rescue ArgumentError => e
          abort e.message
        end

        # Prints `--code-unchanged`'s verdict.
        def report_code_changes(changed)
          changed.each { |path| puts "#{path}: code changed, not just comments" }
          puts "code unchanged" if changed.empty?
          changed.empty? ? 0 : 1
        end

        private

        def print_run(run, found, options)
          if options[:json]
            puts JSON.pretty_generate(found.map(&:to_h))
          elsif options[:mode] == :check
            found.each { |v| puts "#{v.path}:#{v.line}: [#{v.category}] #{v.message}" }
          else
            puts run.report(top: options[:top])
          end
        end

        def mode_options(opts, options)
          opts.on("--report", "summary tables (default)") { options[:mode] = :report }
          opts.on("--check", "list every violation, exit 1 if any") { options[:mode] = :check }
          opts.on("--fix", "rewrite fixable categories: #{FIXABLE.join(", ")}") { options[:mode] = :fix }
          opts.on("--write-baseline", "record every block over #{MAX_BLOCK} lines as tolerated") do
            options[:mode] = :write_baseline
          end
        end

        def filter_options(opts, options)
          opts.on("--only LIST", Array, "limit to: #{CATEGORIES.keys.join(", ")}") { |list| options[:only] = list }
          opts.on("--code-unchanged REF", "exit 1 if any file's code (not comments) differs from REF") do |ref|
            options[:mode] = :code_unchanged
            options[:ref] = ref
          end
          opts.on("--json", "machine-readable output") { options[:json] = true }
          opts.on("--top N", Integer, "rows in the worst-files table") { |n| options[:top] = n }
        end

        # @return [Array(Hash, Array<String>)] the options and the paths, after refusing an unknown
        #   category, a missing path, or no path at all
        def parse_arguments(argv)
          options = { mode: :report, top: 20 }
          parser = option_parser(options)
          paths = parser.parse(argv)
          refuse_unknown_categories(options)
          abort parser.help if paths.empty?
          refuse_missing_paths(paths)
          [options, paths]
        end

        def refuse_unknown_categories(options)
          unknown = Array(options[:only]) - CATEGORIES.keys
          abort "unknown categories: #{unknown.join(", ")}" unless unknown.empty?
        end

        def refuse_missing_paths(paths)
          missing = paths.reject { |path| File.exist?(path) }
          abort "no such path: #{missing.join(", ")}" unless missing.empty?
        end
      end
    end
  end
end
