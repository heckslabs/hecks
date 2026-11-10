# frozen_string_literal: true

require_relative "../git_rehearsal/spec_map"

module Hecks
  module Adapters
    class MainIntegration
      # The checks a verification runs in a clean copy of a landed commit, each a launcher command
      # run there: the quick gate, the specs the changes touch (the changed spec files and the
      # specs `SpecMap` names for the other changes, in batches of at most `BATCH`), the command
      # names, the CI pipeline and the generated corpus, the last two only compared. Nothing here
      # runs the full spec suite.
      class Checks
        # The most spec files one launcher call runs, the local cap of the `test_scope` setting.
        BATCH = 25

        # The most spec files one verification runs; the rest run in CI.
        LIMIT = 100

        # The launcher, as the copy holds it.
        LAUNCHER = "exe/hecks"

        # What every launcher command runs under, as CI runs it: `bundle exec` hands Bundler to
        # each process the command starts, a spec's own subprocess included.
        RUNS_AS = %w[bundle exec].freeze

        # The checks that do not depend on what changed, by name.
        FIXED = {
          "quick gate"    => %w[gate_run.gate! stage=quick --wait],
          "command names" => %w[conformance_run.check_command_names! --wait],
          "ci pipeline"   => %w[regeneration_run.project_ci_pipeline! check.value=true --wait],
          "corpus"        => %w[regeneration_run.regenerate_corpus! check.value=true --wait]
        }.freeze

        # @param directory [String] the clean copy the checks run in
        # @param changed [Array<String>] the paths the landed range changed, relative to the copy
        def initialize(directory, changed)
          @directory = directory
          @changed = changed
        end

        # @return [Array<Array(String, Array<String>)>] each check's name and its command line
        def all
          named = FIXED.map { |name, args| [name, [*RUNS_AS, LAUNCHER, *args]] }
          named.first(1) + spec_batches + named.drop(1)
        end

        # @return [Array<String>] the spec files the checks run, at most `LIMIT`
        def specs
          own = @changed.select { |path| path.end_with?("_spec.rb") && File.file?(File.join(@directory, path)) }
          mapped = GitRehearsal::SpecMap.new(@directory).map(@changed, limit: LIMIT).specs
          (own | mapped).first(LIMIT)
        end

        private

        def spec_batches
          batches = specs.each_slice(BATCH).to_a
          batches.each_with_index.map do |batch, index|
            ["specs #{index + 1}/#{batches.size}",
             [*RUNS_AS, LAUNCHER, "test_suite_run.run_spec_files!", "files.value=#{batch.join(" ")}", "--wait"]]
          end
        end
      end
    end
  end
end
