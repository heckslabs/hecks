# frozen_string_literal: true

require_relative "../gate_memo"
require_relative "ruby_files"

module Hecks
  module Tools
    module GateMemo
      # One stage's use of the memo: which checks a run skips, and what its green results record.
      #
      # A run calls `plan` before it starts and `record` once every check has answered. A check that
      # passed is recorded with the inputs it ran on; a check that failed is forgotten, so it runs
      # again.
      class Session
        # What a run does with the checks it was given.
        #
        # @!attribute [r] run
        #   @return [Array<Hash>] the checks to run; rubocop with the files it lints when
        # incremental
        # @!attribute [r] skipped
        #   @return [Array(Hash, String)] each skipped check and when its green run was recorded
        # @!attribute [r] notes
        #   @return [Array<String>] what the memo could not do, and how each planned check runs
        Plan = Struct.new(:run, :skipped, :notes)

        # @param root [String] the checkout
        # @param env [Hash{String => String}] the environment the stage sets for its checks
        # @param file [String] the memo's file
        def initialize(root:, env:, file: GateMemo.path)
          @root = root
          @env = env
          @file = file
          @ran = []
          @pending = {}
          @notes = []
        end

        # @param checks [Array<Hash>] the checks a run was asked for
        # @return [Plan] the checks to run and the ones skipped; every check runs when the memo is
        # unusable
        def plan(checks)
          @memo, problem = GateMemo.read(@file)
          @readable = problem.nil?
          @memo ||= {}
          @notes << "gate memo unusable (#{problem}): every check runs, and nothing is recorded" unless @readable
          result = Plan.new([], [], @notes)
          checks.each { |check| check["id"] == "rubocop" ? rubocop(check, result) : generic(check, result) }
          result
        end

        # @param results [Hash{String => Array}] each check that ran: its output, and whether it
        # passed
        # @return [Array<String>] what could not be recorded; empty when the memo was written
        def record(results)
          return [] unless @readable

          @ran.each { |id| update(id, results.fetch(id).last) }
          error = GateMemo.write(@memo, @file)
          error ? ["gate memo not written (#{error}): the next run runs these checks in full"] : []
        end

        private

        # @return [void] a check with declared inputs is skipped when its inputs hash as its green
        # run did
        def generic(check, result)
          tree = GateMemo.tree(@root, check["id"])
          inputs = GateMemo.digest(@root, check, @env, tree)
          entry = @memo[check["id"]]
          return result.skipped << [check, entry["at"]] if GateMemo.reusable?(entry, inputs)

          run(check, result, inputs ? GateMemo.green(inputs, tree) : nil)
        end

        # @return [void] RuboCop runs on the files its green run did not cover, or on all of them
        def rubocop(check, result)
          entry = @memo["rubocop"]
          now = RubyFiles.hashes(@root)
          mode, files, why = RubyFiles.plan(@root, entry, now)
          return result.skipped << [check, entry["at"]] if mode == :skip

          result.notes << "rubocop #{mode}: #{why}"
          run(rubocop_check(check, mode, files), result, rubocop_entry(now))
        end

        # @return [Hash] the check, with the files it lints appended when the run is incremental
        def rubocop_check(check, mode, files)
          mode == :incremental ? check.merge("run" => check["run"] + files) : check
        end

        # @return [Hash] the green entry a passing RuboCop run records: its config and every Ruby
        # file
        def rubocop_entry(now) = GateMemo.green(RubyFiles.config(@root)).merge("files" => now)

        # @return [void] the check joins the run; its green entry is kept when it passes
        def run(check, result, entry)
          result.run << check
          @ran << check["id"]
          @pending[check["id"]] = entry
        end

        # @return [void] keeps a passed check's entry, and forgets a check that did not pass
        def update(id, passed)
          entry = @pending[id]
          if passed && entry
            @memo[id] = entry
          else
            @memo.delete(id)
          end
        end
      end
    end
  end
end
