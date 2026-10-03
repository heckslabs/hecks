# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../tools"

module Hecks
  module Tools
    # Projects the `CiGate` rows of the Vocabulary chapter into the workflows: each row becomes a
    # detector job between a pair of marker comments in its `workflow`. The job runs
    # `hecks decide_ci_gate gate=<name>` (`CiGateDecision`), so the decision is made by the binary
    # from the same row, never by shell the workflow carries.
    #
    # Everything outside the markers is hand-written and left alone. With `--check` nothing is
    # written: the tool answers 1 and names each workflow whose region differs from the rows.
    module CiGates
      # Where the workflows live, relative to the checkout.
      WORKFLOWS = ".github/workflows"

      module_function

      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when `--check` finds a region out of date
      # @raise [SystemExit] when a workflow has no marked region for a gate
      def main(argv, root: Tools::ROOT)
        stale = projection(root).reject { |path, text| File.read(path) == text }.keys
        return report(stale, root) if argv.include?("--check")

        stale.each { |path| File.write(path, projection(root).fetch(path)) }
        stale.each { |path| puts "wrote #{path.delete_prefix("#{root}/")}" }
        puts "ci_gates: #{gates.size} gates, every region current" if stale.empty?
        0
      end

      # @param root [String] the checkout
      # @return [Hash{String => String}] each workflow's absolute path to the text it should hold
      def projection(root)
        gates.group_by { |gate| gate.fetch("workflow") }.to_h do |workflow, rows|
          path = File.join(root, WORKFLOWS, workflow)
          [path, rows.reduce(File.read(path)) { |text, gate| replace_region(text, gate, workflow) }]
        end
      end

      # The values a row's `mode` and `push` may take: the language holds one closed set to a value
      # object, so the rest are held here.
      MODES = %w[touches skips_unless].freeze
      PUSHES = %w[skip before_sha].freeze

      # @return [Array<Hash{String => String}>] the `CiGate` rows
      # @raise [SystemExit] when a row's `mode` or `push` is not one the action understands
      def gates
        Hecks::Vocabulary.rows("CiGate").each do |gate|
          abort "ci_gates: #{gate['name']} has mode #{gate['mode'].inspect}" unless MODES.include?(gate["mode"])
          abort "ci_gates: #{gate['name']} has push #{gate['push'].inspect}" unless PUSHES.include?(gate["push"])
        end
      end

      # @param stale [Array<String>] absolute paths whose text differs from the rows
      # @param root [String] the checkout
      # @return [Integer] 0 when current, else 1 with the stale workflows on stderr
      def report(stale, root)
        if stale.empty?
          puts "ci_gates: #{gates.size} gates, every region current"
          return 0
        end

        warn "ci_gates: out of date: #{stale.map { |path| path.delete_prefix("#{root}/") }.join(', ')} " \
             "(run hecks project_ci_gates)"
        1
      end

      # @param text [String] a workflow
      # @param gate [Hash{String => String}] a `CiGate` row
      # @param workflow [String] the workflow's file name, for the refusal
      # @return [String] the workflow with the gate's marked region replaced by its job
      def replace_region(text, gate, workflow)
        name = gate.fetch("name")
        region = /^  # BEGIN GENERATED ci_gate #{Regexp.escape(name)}\b.*?^  # END GENERATED ci_gate #{Regexp.escape(name)}$/m
        abort "ci_gates: #{workflow} has no BEGIN/END GENERATED ci_gate #{name} region" unless text.match?(region)

        text.sub(region) { job(gate) }
      end

      # @param gate [Hash{String => String}] a `CiGate` row
      # @return [String] the marked region: the detector job that answers `touched`
      def job(gate)
        name = gate.fetch("name")
        [
          "  # BEGIN GENERATED ci_gate #{name} (CiGate vocabulary; hecks project_ci_gates). Do not hand-edit.",
          "  #{name}:",
          "    runs-on: ubuntu-latest",
          "    timeout-minutes: 10",
          *job_condition(gate),
          "    outputs:",
          "      touched: ${{ steps.diff.outputs.touched }}",
          "    steps:",
          "      - uses: actions/checkout@v4",
          "        with:",
          "          # Full history: the diff needs both endpoints present as real objects.",
          "          fetch-depth: 0",
          "      - uses: ./.github/actions/setup-ruby",
          "      - uses: ./.github/actions/hecks-environment",
          "      - id: diff",
          "        name: #{quoted(gate.fetch('label'))}",
          "        run: bundle exec exe/hecks decide_ci_gate gate=#{name} --wait",
          "  # END GENERATED ci_gate #{name}"
        ].join("\n")
      end

      # @param gate [Hash{String => String}] a `CiGate` row
      # @return [Array<String>] the job-level `if:` lines for a gate that skips push runs
      def job_condition(gate)
        return [] unless gate.fetch("push") == "skip"

        ["    # A push is a cache-warming run; the jobs that need this one skip through their `needs:`.",
         "    if: github.event_name != 'push'"]
      end

      # @param text [String]
      # @return [String] the text as a single-quoted YAML scalar
      def quoted(text) = "'#{text.gsub("'", "''")}'"
    end
  end
end
