# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module CLI
    # The command behind `hecks list_io_parallel_specs`: prints, one per line, the spec files with
    # at least one example matching an RSpec tag filter. ci.yml hands the list to `parallel_rspec`
    # instead of the whole `spec` directory.
    #
    # Given every spec file, parallel_tests ignores the runtime log unless it covers about 67% of
    # them, so a tag-filtered job silently groups by file size. A dry run, not grep, picks the
    # files so inherited tags, `~fuzzing` and shared examples count.
    #
    # The list is committed (`.github/postgres_io_spec_files.txt`). `--write FILE` refreshes it;
    # `--check FILE` (CI's postgres_io_file_list job) fails on a stale list.
    #
    #   hecks list_io_parallel_specs '<exclude-pattern regex>' -- --tag io --tag ~fuzzing
    module RspecIoParallelFiles
      module_function

      # Lists the matching files, writes them, or checks a committed list.
      #
      # @param argv [Array<String>] `--check FILE` or `--write FILE` optionally, the exclude
      #   pattern, `--`, then the RSpec tag arguments
      # @param root [String] the checkout whose `spec/` is searched; the dry run runs there
      # @param out [IO] where the list goes when neither flag is given
      # @param err [IO] where the tally and any staleness go
      # @return [Integer] the exit status, 0 once done
      # @raise [SystemExit] on a bad command line, an empty candidate set, a failed dry run, or a
      #   stale committed list
      def call(argv, root: Dir.pwd, out: $stdout, err: $stderr)
        argv = argv.dup
        mode, list_path = argv.shift(2) if %w[--check --write].include?(argv.first)
        abort "hecks list_io_parallel_specs: #{mode} needs a file path" if mode && list_path.nil?

        exclude_arg, tag_args = parse(argv)
        candidates = Dir.glob("spec/**/*_spec.rb", base: root).grep_v(Regexp.new(exclude_arg)).sort
        refuse_empty_candidates(candidates)
        files, example_count = matching_files(candidates, tag_args, root, err)
        err.puts "hecks list_io_parallel_specs: #{files.size} of #{candidates.size} candidate files carry a " \
                 "matching example (#{example_count} examples total) under `#{tag_args.join(" ")}`"

        case mode
        when "--write" then File.write(File.expand_path(list_path, root), "#{files.join("\n")}\n")
        when "--check" then check(files, File.expand_path(list_path, root), list_path, exclude_arg, tag_args, err)
        else out.puts files
        end
        0
      end

      # @param argv [Array<String>] the exclude pattern, `--`, and the tag arguments
      # @return [Array(String, Array<String>)] the pattern and the tag arguments
      # @raise [SystemExit] with the usage line when either is missing
      def parse(argv)
        exclude_arg, *rest = argv
        separator = rest.index("--")
        usage = "usage: hecks list_io_parallel_specs '<exclude-pattern regex>' -- <rspec tag args...>"
        abort usage unless exclude_arg && separator
        tag_args = rest[(separator + 1)..]
        abort usage if tag_args.nil? || tag_args.empty?

        [exclude_arg, tag_args]
      end

      # @param candidates [Array<String>] the spec files left after the exclude pattern
      # @return [void]
      # @raise [SystemExit] when there are none, which means a broken pattern or an empty checkout
      def refuse_empty_candidates(candidates)
        return unless candidates.empty?

        abort "hecks list_io_parallel_specs: found ZERO candidate spec files after applying the exclude " \
              "pattern — that's almost certainly a broken pattern or an empty checkout, not a real empty " \
              "test suite. Refusing to silently hand parallel_rspec nothing to run."
      end

      # Asks RSpec for a dry run of the candidates under the tag filter.
      #
      # @param candidates [Array<String>] the spec files to ask about
      # @param tag_args [Array<String>] the RSpec tag arguments
      # @param root [String] the directory the dry run runs in
      # @param err [IO] where a failed run's stderr goes
      # @return [Array(Array<String>, Integer)] the files with a matching example, and how many
      #   examples matched
      # @raise [SystemExit] when the dry run fails, prints no JSON, or matches nothing
      def matching_files(candidates, tag_args, root, err)
        command = ["bundle", "exec", "rspec", "--dry-run", *tag_args, "--format", "json", *candidates]
        stdout, stderr, status = Open3.capture3(*command, chdir: root)
        unless status.success?
          err.puts stderr
          abort "hecks list_io_parallel_specs: `#{command.join(" ")}` exited #{status.exitstatus} — " \
                "see stderr above. Refusing to guess a file list from a failed dry run."
        end

        start = stdout.index('{"version"')
        abort "hecks list_io_parallel_specs: couldn't find RSpec's JSON output in the dry-run's stdout:\n#{stdout}" unless start

        examples = JSON.parse(stdout[start..])["examples"] || []
        files = examples.map { |e| e.fetch("file_path").sub(%r{\A\./}, "") }.uniq.sort
        return [files, examples.size] unless files.empty?

        abort "hecks list_io_parallel_specs: #{candidates.size} candidate files, but the dry run matched ZERO " \
              "examples under `#{tag_args.join(" ")}` — that's almost certainly a broken tag filter, not a " \
              "real empty set. Refusing to silently hand parallel_rspec nothing to run."
      end

      # @param files [Array<String>] the files that carry a matching example
      # @param path [String] the committed list's absolute path
      # @param shown [String] the path as the person typed it
      # @param exclude_arg [String] the exclude pattern, for the refresh command
      # @param tag_args [Array<String>] the tag arguments, for the refresh command
      # @param err [IO] where the difference goes
      # @return [void]
      # @raise [SystemExit] when the committed list differs
      def check(files, path, shown, exclude_arg, tag_args, err)
        committed = File.exist?(path) ? File.readlines(path, chomp: true).reject(&:empty?) : []
        missing = files - committed
        stale = committed - files
        return if missing.empty? && stale.empty?

        err.puts "#{shown} is out of date."
        err.puts named("carries a matching example but is not listed (would never run in the shards)", missing) if missing.any?
        err.puts named("listed but carries no matching example any more", stale) if stale.any?
        abort "Refresh it and commit the result:\n  " \
              "hecks list_io_parallel_specs --write #{shown} '#{exclude_arg}' -- #{tag_args.join(" ")}"
      end

      # @param heading [String] what the paths have in common
      # @param paths [Array<String>] the paths
      # @return [String] the heading with the paths under it
      def named(heading, paths)
        "  #{heading}:\n    #{paths.join("\n    ")}"
      end
    end
  end
end
