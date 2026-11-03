# frozen_string_literal: true

require "open3"
require_relative "tree"
require_relative "spec_files"
require_relative "changed_specs"
require_relative "../git_rehearsal/spec_map"
require_relative "../git_rehearsal/impacted"
require_relative "../git_rehearsal/impacted/skips"

module Hecks
  module Adapters
    module Codebase
      # The specs a branch's changes touch, found by the push rehearsal's own map and run in one
      # launcher boot.
      #
      # The changed files are those between the merge base with the base ref and the working tree
      # (uncommitted and untracked files included). `GitRehearsal::SpecMap` names the specs, and
      # `GitRehearsal::Impacted::Skips` leaves out those that need `cargo`, `gh` or the network, and
      # the `:io` ones when no scratch Postgres answers, exactly as the rehearsal's stage does.
      class ImpactedSpecs
        # The most spec files a run takes, as the rehearsal's stage does.
        DEFAULT_CAP = GitRehearsal::Impacted::DEFAULT_LIMIT

        DIGITS = /\d+/
        TOTALS = /\d+ examples?, \d+ failures?\z/

        # @param tree [Tree] the checkout
        # @param scratch [#call, nil] says whether a scratch Postgres answers; `pg_isready` when nil
        # @param files [SpecFiles, nil] runs the mapped specs
        def initialize(tree, scratch: nil, files: nil)
          @tree = tree
          @scratch = scratch || -> { scratch_answers? }
          @files = files || SpecFiles.new(tree)
        end

        # @param base [String] the ref the branch is compared with
        # @param cap [Integer] the most spec files to run
        # @param dry [Boolean] list the mapped specs and run none
        # @param run_options [Hash] `isolation`, `example`, `env` and `tags`, as `SpecFiles#run`
        #   takes them
        # @return [String] the changed files, the mapped, skipped and run specs and how each ended
        # @raise [ConsoleCapture::Failure] when git refuses or a spec fails
        def call(base:, cap: DEFAULT_CAP, dry: false, **run_options)
          changed = changed_files(base)
          skips = GitRehearsal::Impacted::Skips.new(@tree.root, scratch: @scratch)
          mapping = GitRehearsal::SpecMap.new(@tree.root).map(changed, limit: cap, skip: skips)
          head = describe(base, changed, mapping)
          return "#{head}\nnothing impacted; nothing run" if mapping.specs.empty?
          return "#{head}\ndry run: no spec run" if dry

          [head, run(mapping.specs, skips, run_options)].join("\n\n")
        end

        private

        def changed_files(base)
          merge, status = Open3.capture2e("git", "-C", @tree.root, "merge-base", "HEAD", base)
          ChangedSpecs.changed_files(@tree, status.success? ? merge.strip : base)
        end

        def describe(base, changed, mapping)
          lines = ["changed since #{base}: #{changed.size} file(s)", *changed.map { |file| "  #{file}" },
                   "impacted specs: #{mapping.specs.size}", *mapping.specs.map { |spec| "  #{spec}" }]
          lines << mapping.cap_note unless mapping.cap_note.empty?
          (lines + mapping.skipped.map { |spec, why| "skipped: #{spec} (#{why})" }).join("\n")
        end

        # The `:io` specs run as CI does (`CI=true`), the rest as they are; with both, the report
        # ends with the counts of both runs together.
        def run(specs, skips, options)
          io, plain = specs.partition { |spec| skips.io?(spec) }
          env = options.fetch(:env, {})
          groups = [[plain, env], [io, env.merge("CI" => "true")]].reject { |group, _env| group.empty? }
          reports = groups.map { |group, group_env| batch(group, options.merge(env: group_env)) }
          answer(reports)
        end

        def answer(reports)
          text = (reports.map(&:text) + [(combined(reports) if reports.size > 1)]).compact.join("\n\n")
          raise ConsoleCapture::Failure, text if reports.any?(&:failed)

          text
        end

        # What a batch said, and whether a file of it failed.
        Batch = Struct.new(:text, :failed)

        def batch(group, options)
          Batch.new(@files.run(files: group, **options), false)
        rescue ConsoleCapture::Failure => e
          Batch.new(e.message, true)
        end

        def combined(reports)
          counts = reports.map { |report| final_counts(report.text) }
          "#{counts.sum(&:first)} examples, #{counts.sum(&:last)} failures"
        end

        def final_counts(text) = text[TOTALS].scan(DIGITS).map(&:to_i)

        def scratch_answers?
          Open3.capture2e("pg_isready").last.success?
        rescue SystemCallError
          false
        end
      end
    end
  end
end
