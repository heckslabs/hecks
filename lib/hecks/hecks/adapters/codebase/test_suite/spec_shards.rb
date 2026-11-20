# frozen_string_literal: true

require "hecks/ci_speed/shard_planner"
require_relative "../../console_capture"

module Hecks
  module Adapters
    module Codebase
      module TestSuite
        # The spec files of one group (1-indexed) of an N-way split by the shared `ShardPlanner`,
        # which `TestSuiteRun.ShardSpecs` answers. It is the split a leg of `rspec_shard` in
        # ci-rspec.yml falls back on when the plan job's plan cannot be read; with no runtime log it
        # balances by file size, which every leg computes alike.
        #
        # It does not use `parallel_rspec --only-group`, which forces one process per leg; this
        # suite is CPU-bound, so each leg would use one of four vCPUs.
        module SpecShards
          module_function

          # @param root [String] the checkout whose `spec/` is split
          # @param group [Integer] the group wanted, 1-indexed
          # @param groups [Integer] how many groups the files are split into
          # @param runtime_log [String, nil] a log of `path:seconds` lines, relative to `root`
          # @return [Array<String>] the group's spec files, relative to the checkout
          # @raise [ConsoleCapture::Failure] when the group is outside the split or there are no
          #   specs
          def files(root:, group:, groups:, runtime_log: nil)
            raise ConsoleCapture::Failure, "group must be between 1 and #{groups}, got #{group}" unless (1..groups).cover?(group)

            log = runtime_log && File.expand_path(runtime_log, root)
            Dir.chdir(root) { groups_of(spec_files(root), groups, log) }[group - 1] || []
          end

          # @param root [String] the checkout whose `spec/` is split
          # @return [Array<String>] the spec files, relative to the checkout
          # @raise [ConsoleCapture::Failure] when there are none
          def spec_files(root)
            files = Dir.glob("spec/**/*_spec.rb", base: root)
            return files unless files.empty?

            raise ConsoleCapture::Failure, "found ZERO spec files under spec/ — refusing to hand parallel_rspec nothing to run"
          end

          # Splits the files by the seconds in the runtime log when one exists, by file size
          # otherwise.
          #
          # @param files [Array<String>] the spec files, relative to the checkout
          # @param groups [Integer] how many groups to split into
          # @param runtime_log [String, nil] a log of `path:seconds` lines, used when the file
          #   exists
          # @return [Array<Array<String>>] the files of each group
          def groups_of(files, groups, runtime_log)
            table = runtime_log && File.exist?(runtime_log) ? ShardPlanner.parse(File.read(runtime_log)) : {}
            prices = ShardPlanner.prices(files, table, ->(file) { File.size(file) })
            ShardPlanner.partition(files, groups, prices)
          end
        end
      end
    end
  end
end
