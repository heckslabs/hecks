# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "yaml"

module Hecks
  module CLI
    # The command behind `hecks refresh_runtime_baseline`: regenerates the committed runtime
    # baselines the sharded CI jobs group from. It prefers one CI run's timings; a local run is
    # the fallback.
    #
    #   hecks refresh_runtime_baseline --from-run <run-id>   # preferred: one CI run's timings
    #   hecks refresh_runtime_baseline [workers]             # fallback: this machine only
    #
    # `--from-run` reads the runtime-log artifacts of a successful run and writes a family only
    # when every leg uploaded one; a partial set would skew the split. Runner seconds differ from a
    # laptop's, so a local baseline misses subprocess-heavy specs. The local mode refuses a red run.
    module RefreshRspecRuntimeBaseline
      REPO = "heckslabs/hecks"
      USAGE = "usage: hecks refresh_runtime_baseline --from-run <run-id> | [workers]"

      # Only `spec/..._spec.rb:<seconds>` lines; RSpec's "Run options" line must not be copied
      # into a committed file. Seconds can arrive in exponent form (`9.69e-05`).
      RUNTIME_LINE = %r{\A(?<file>spec/\S+_spec\.rb):(?<seconds>\d+(?:\.\d+)?(?:e-?\d+)?)\z}

      # What a `--from-run` refresh works with: the checkout, the CI run, where its artifacts
      # download to, and where progress goes.
      Download = Struct.new(:root, :run_id, :dir, :out)

      module_function

      # Refreshes the baselines from a CI run or a local run.
      #
      # @param argv [Array<String>] `--from-run RUN_ID`, or optionally the local worker count
      # @param root [String] the checkout whose `.github/` baselines are rewritten
      # @param out [IO] where what was written goes
      # @return [Integer] the exit status, 0 once written
      # @raise [SystemExit] when the run is unreadable or unsuccessful, the local suite is red, or
      #   no artifact family is complete
      def call(argv, root:, out: $stdout)
        if argv.first == "--from-run"
          from_run(root, argv.fetch(1) { abort USAGE }, out)
        else
          from_local(root, argv.fetch(0) { abort USAGE }, out)
        end
        0
      end

      # Reads the leg counts from the workflow matrix so a resize cannot leave a stale count here.
      #
      # @param root [String] the checkout
      # @return [Hash{String => Hash}] each artifact family's leg count and baseline file
      def families(root)
        {
          "rspec-runtime-group"       => { legs:     matrix_legs(root, "ci-rspec.yml", "rspec_shard"),
                                           baseline: ".github/rspec_runtime_baseline.log" },
          "postgres-io-runtime-group" => { legs:     matrix_legs(root, "ci-postgres-io-parallel.yml",
                                                                 "rspec_postgres_io_parallel_shard"),
                                           baseline: ".github/postgres_io_runtime_baseline.log" }
        }
      end

      # @param root [String] the checkout
      # @param workflow [String] the workflow file's name
      # @param job [String] the job whose matrix is counted
      # @return [Integer] how many groups the job's matrix has
      def matrix_legs(root, workflow, job)
        YAML.load_file(File.join(root, ".github/workflows", workflow)).dig("jobs", job, "strategy", "matrix", "group").size
      end

      # @param paths [Array<String>] runtime logs
      # @return [Array<String>] one sorted `file:seconds` line per spec file
      def baseline_lines(paths)
        seconds_by_file = paths.flat_map { |path| File.readlines(path) }.filter_map do |line|
          match = RUNTIME_LINE.match(line.strip) or next
          [match[:file], Float(match[:seconds])]
        end.to_h
        seconds_by_file.map { |file, seconds| format("%<file>s:%<seconds>.2f", file: file, seconds: seconds) }.sort
      end

      # @param root [String] the checkout
      # @param relative [String] the baseline's path under the checkout
      # @param lines [Array<String>] the baseline's lines
      # @param out [IO] where the note goes
      # @return [void]
      def write_baseline(root, relative, lines, out)
        File.write(File.join(root, relative), "#{lines.join("\n")}\n")
        out.puts "wrote #{relative}: #{lines.size} spec files"
      end

      # @param run_id [String] the CI run's id
      # @return [void]
      # @raise [SystemExit] when `gh` cannot read the run or it did not succeed
      def refuse_unless_successful!(run_id)
        out, status = Open3.capture2("gh", "run", "view", run_id, "-R", REPO, "--json", "conclusion")
        abort "hecks refresh_runtime_baseline: could not read run #{run_id}" unless status.success?

        conclusion = JSON.parse(out)["conclusion"]
        return if conclusion == "success"

        abort "hecks refresh_runtime_baseline: run #{run_id} concluded #{conclusion.inspect} — " \
              "refusing to write a baseline from anything but a successful run"
      end

      # @param root [String] the checkout
      # @param run_id [String] the CI run's id
      # @param out [IO] where what was written goes
      # @return [void]
      # @raise [SystemExit] when no family of artifacts is complete
      def from_run(root, run_id, out)
        refuse_unless_successful!(run_id)
        dir = File.join(root, "tmp/ci-runtime-#{run_id}")
        FileUtils.rm_rf(dir)

        download = Download.new(root, run_id, dir, out)
        written = families(root).count { |prefix, family| refresh_family(download, prefix, family) }
        return unless written.zero?

        abort "hecks refresh_runtime_baseline: run #{run_id} had no complete artifact family — nothing written"
      end

      # Downloads one artifact family and writes its baseline when every leg uploaded a log.
      #
      # @api private
      # @return [Boolean] whether the family was complete and written
      def refresh_family(download, prefix, family)
        logs = download_logs(download, prefix)
        legs = logs.map { |path| File.basename(File.dirname(path)) }.uniq.size
        complete = legs == family[:legs]
        if complete
          write_baseline(download.root, family[:baseline], baseline_lines(logs), download.out)
        else
          warn "skipping #{family[:baseline]}: run #{download.run_id} has #{legs} of #{family[:legs]} #{prefix}-* artifacts"
        end
        complete
      end

      # @api private
      def download_logs(download, prefix)
        system("gh", "run", "download", download.run_id, "-R", REPO, "-p", "#{prefix}-*", "-D", download.dir,
               out: File::NULL, err: File::NULL)
        Dir[File.join(download.dir, "#{prefix}-*", "*.log")]
      end

      # @param root [String] the checkout
      # @param workers [String] how many `parallel_rspec` workers to time with
      # @param out [IO] where what was written goes
      # @return [void]
      # @raise [SystemExit] when the local suite is red
      def from_local(root, workers, out)
        raw = "tmp/rspec_runtime_baseline.raw.log"
        FileUtils.mkdir_p(File.join(root, "tmp"))
        FileUtils.rm_f(File.join(root, raw))

        formatters = "--tag ~io --tag ~fuzzing --format progress --format ParallelTests::RSpec::RuntimeLogger --out #{raw}"
        green = system("bundle", "exec", "parallel_rspec", "spec", "-n", workers, "-o", formatters, chdir: root)
        abort "hecks refresh_runtime_baseline: the spec run failed — not writing a baseline from a red suite" unless green

        write_baseline(root, families(root).fetch("rspec-runtime-group")[:baseline],
                       baseline_lines([File.join(root, raw)]), out)
      end
    end
  end
end
