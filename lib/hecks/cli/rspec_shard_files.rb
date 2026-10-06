# frozen_string_literal: true

require "parallel_tests/test/runner"

module Hecks
  module CLI
    # The command behind `hecks shard_specs`: prints the spec files assigned to one group
    # (1-indexed) of a runtime-balanced N-way split. `rspec_shard` in ci-rspec.yml passes the
    # committed runtime baseline so every leg agrees.
    #
    # It does not use `parallel_rspec --only-group`, which forces one process per leg; this suite
    # is CPU-bound, so each leg would use one of four vCPUs. The group's list comes from
    # `tests_in_groups`, leaving `parallel_rspec` its own workers.
    module RspecShardFiles
      USAGE = "usage: hecks shard_specs <group 1-indexed> <num_groups> [runtime_log_path]"

      module_function

      # Prints the files of one group.
      #
      # @param argv [Array<String>] the group, the number of groups, and optionally a runtime log
      # @param root [String] the checkout whose `spec/` is split
      # @param out [IO] where the files go, one per line
      # @param err [IO] where the group's size goes
      # @return [Integer] the exit status, 0 once printed
      # @raise [SystemExit] on missing or out-of-range arguments, or when there are no spec files
      def call(argv, root: Dir.pwd, out: $stdout, err: $stderr)
        group, num_groups, runtime_log = parse_group(argv)
        files = spec_files(root)

        groups = Dir.chdir(root) { groups_of(files, num_groups, runtime_log && File.expand_path(runtime_log, root)) }
        selected = groups[group - 1] || []
        err.puts "hecks shard_specs: group #{group}/#{num_groups} has #{selected.size} of #{files.size} files"
        out.puts selected
        0
      end

      # @param argv [Array<String>] the group, the number of groups, and optionally a runtime log
      # @return [Array(Integer, Integer, String)] the group, the number of groups, the log path
      # @raise [SystemExit] on missing or out-of-range arguments
      def parse_group(argv)
        group_arg, num_groups_arg, runtime_log = argv
        abort USAGE unless group_arg && num_groups_arg

        group = Integer(group_arg)
        num_groups = Integer(num_groups_arg)
        abort "group must be between 1 and #{num_groups}, got #{group}" unless (1..num_groups).cover?(group)

        [group, num_groups, runtime_log]
      end

      # @param root [String] the checkout whose `spec/` is split
      # @return [Array<String>] the spec files, relative to the checkout
      # @raise [SystemExit] when there are none
      def spec_files(root)
        files = Dir.glob("spec/**/*_spec.rb", base: root)
        return files unless files.empty?

        abort "hecks shard_specs: found ZERO spec files under spec/ — " \
              "refusing to hand parallel_rspec nothing to run"
      end

      # Splits the files by recorded runtime, falling back to file size on a cold cache.
      #
      # `allowed_missing_percent` covers gaps inside a log, not a missing file (`Runner.runtimes`
      # raises `Errno::ENOENT`).
      #
      # @param files [Array<String>] the spec files, relative to the checkout
      # @param num_groups [Integer] how many groups to split into
      # @param runtime_log [String, nil] the runtime log's path, used when the file exists
      # @return [Array<Array<String>>] the files of each group
      def groups_of(files, num_groups, runtime_log)
        options = { group_by: :runtime, allowed_missing_percent: 100 }
        options[:runtime_log] = runtime_log if runtime_log && File.exist?(runtime_log)
        ParallelTests::Test::Runner.tests_in_groups(files, num_groups, **options)
      rescue Errno::ENOENT
        ParallelTests::Test::Runner.tests_in_groups(files, num_groups, group_by: :filesize)
      end
    end
  end
end
