# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "../../fuzzing/qa_settings"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.mutate`: mutation testing of the Rust
    # kernel. `cargo mutants` changes one operator or return value at a time and runs the tests; a
    # mutant they do not catch is a line no test pins.
    #
    # `--from-dials` takes the files from the `mutation_files` dial, which is how
    # `hecks quality_control sweep.tick` runs it; an empty list turns the step off. Mutants named in
    # `mutation_equivalent` behave the same as the original code, so they are never run.
    #
    # Exit codes: 0 every mutant caught; 2 a mutant missed or timed out; 1 an operational error.
    class QaMutate
      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_FOUND = 2

      USAGE = "usage: hecks quality_control mutate [--file rust/src/<file>.rs ...] [--from-dials]"

      # cargo-mutants' own exit statuses: 2 a mutant missed, 3 one timed out.
      CARGO_FOUND = [2, 3].freeze

      # The cargo-mutants outcome files, in the order the report lists them.
      OUTCOMES = %w[caught missed timeout unviable].freeze

      # Runs cargo-mutants over the files and reports.
      #
      # @param argv [Array<String>] `--file` paths, or `--from-dials`
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `HECKS_QA_SETTINGS_PATH` reads another settings file;
      #   `QA_MUTATION_FILES` overrides the files of `--from-dials`
      # @return [Integer] 0 every mutant caught, 2 one survived, 1 an operational error
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `HECKS_QA_SETTINGS_PATH` reads another settings file;
      #   `QA_MUTATION_FILES` overrides the files of `--from-dials`
      def initialize(root:, env: ENV)
        @root = root
        @env = env
      end

      # @param argv [Array<String>] `--file` paths, or `--from-dials`
      # @return [Integer] the exit status
      def call(argv)
        return usage(EXIT_OK) if %w[-h --help].include?(argv.first)

        files = files_from(argv)
        return usage(EXIT_ERROR) if files.nil?
        return off if files.empty?

        run(files)
      end

      private

      def usage(status)
        (status == EXIT_OK ? $stdout : $stderr).puts USAGE
        status
      end

      def off
        puts "mutation: off (no mutation_files)"
        EXIT_OK
      end

      # `QA_MUTATION_FILES` (comma-separated, empty for none) overrides the dial for one run.
      #
      # @return [Array<String>, nil] paths relative to `rust/`, nil for an argument it does not take
      def files_from(argv)
        files = argv == ["--from-dials"] ? dial_files : named_files(argv)
        files&.map { |path| relative_to_rust(path) }
      end

      # @return [Array<String>, nil] each `--file` path, nil unless argv is only `--file` pairs
      def named_files(argv)
        pairs = argv.each_slice(2).to_a
        return nil if pairs.empty? || pairs.any? { |flag, path| flag != "--file" || path.nil? }

        pairs.map(&:last)
      end

      def dial_files
        override = @env["QA_MUTATION_FILES"]
        override ? override.split(",").map(&:strip).reject(&:empty?) : settings.mutation_files
      end

      def relative_to_rust(path) = path.delete_prefix("rust/")

      def settings
        @settings ||= Hecks::Fuzzing::QaSettings.load(
          @env.fetch("HECKS_QA_SETTINGS_PATH", Hecks::Fuzzing::QaSettings::DEFAULT_PATH)
        )
      end

      def run(files)
        out_dir = File.join(@root, "tmp/qa-mutants")
        FileUtils.rm_rf(File.join(out_dir, "mutants.out"))
        FileUtils.mkdir_p(out_dir)
        puts "mutation: #{files.join(", ")}"
        output, status = Open3.capture2e(*cargo_argv(files, out_dir), chdir: File.join(@root, "rust"))
        report(output, status.exitstatus, File.join(out_dir, "mutants.out"))
      rescue Errno::ENOENT => e
        warn "mutation: cannot run cargo-mutants (#{e.message}); install it with `cargo install cargo-mutants`"
        EXIT_ERROR
      end

      # `--in-place` because `pattern.rs` `include_str!`s fixtures outside `rust/`, which a copied
      # tree lacks. cargo-mutants puts each file back as it goes; a run killed mid-mutant leaves one
      # changed, and the next tick's clean-tree check refuses until it is reverted.
      def cargo_argv(files, out_dir)
        excluded = settings.mutation_equivalent.flat_map { |name| ["--exclude-re", Regexp.escape(name)] }
        ["cargo", "mutants", "--in-place", "--no-shuffle", "--output", out_dir,
         *files.flat_map { |file| ["--file", file] }, *excluded]
      end

      def report(output, cargo_exit, results)
        counts = OUTCOMES.to_h { |outcome| [outcome, outcome_lines(results, outcome)] }
        return operational_error(output, cargo_exit) unless cargo_exit.zero? || CARGO_FOUND.include?(cargo_exit)

        puts summary(counts)
        survivors = counts["missed"] + counts["timeout"]
        survivors.empty? ? EXIT_OK : found(survivors, results)
      end

      def found(survivors, results)
        puts "FOUND SOMETHING (#{survivors.size} mutant(s) no test caught):"
        survivors.each { |line| puts "  #{line}" }
        puts "full results: #{results}"
        EXIT_FOUND
      end

      def outcome_lines(results, outcome)
        path = File.join(results, "#{outcome}.txt")
        File.file?(path) ? File.readlines(path, chomp: true).reject(&:empty?) : []
      end

      # Caught over caught plus missed: a timeout is reported beside it, and an unviable mutant
      # did not compile, so no test was asked about it.
      def summary(counts)
        caught, missed = counts.values_at("caught", "missed").map(&:size)
        rate = (caught + missed).positive? ? format("%.1f%%", 100.0 * caught / (caught + missed)) : "n/a"
        parts = OUTCOMES.map { |outcome| "#{counts[outcome].size} #{outcome}" }
        "mutation: #{parts.join(", ")}; kill rate #{rate}"
      end

      def operational_error(output, cargo_exit)
        warn output
        warn "mutation: cargo mutants ended with status #{cargo_exit.inspect}"
        EXIT_ERROR
      end
    end
  end
end
