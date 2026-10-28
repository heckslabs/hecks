# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../tools"

module Hecks
  module Tools
    # Projects the `CiShards` rows of the Vocabulary bluebook into the workflows: each row becomes
    # the `strategy:` block of its job, between a pair of marker comments in its `workflow`. The
    # job's own steps read the count back as `strategy.job-total`, so the row is the only place
    # that states it.
    #
    # Everything outside the markers is hand-written and left alone. With `--check` nothing is
    # written: the tool answers 1 and names each workflow whose region differs from the rows.
    module CiShards
      # Where the workflows live, relative to the checkout.
      WORKFLOWS = ".github/workflows"

      module_function

      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when `--check` finds a region out of date
      # @raise [SystemExit] when a workflow has no marked region for a job
      def main(argv, root: Tools::ROOT)
        files = projection(root)
        stale = files.reject { |path, text| File.read(path) == text }.keys
        return report(stale, root) if argv.include?("--check")

        stale.each do |path|
          File.write(path, files.fetch(path))
          puts "wrote #{path.delete_prefix("#{root}/")}"
        end
        puts "ci_shards: #{shards.size} sharded jobs, every region current" if stale.empty?
        0
      end

      # @param root [String] the checkout
      # @return [Hash{String => String}] each workflow's absolute path to the text it should hold
      def projection(root)
        shards.group_by { |row| row.fetch("workflow") }.to_h do |workflow, rows|
          path = File.join(root, WORKFLOWS, workflow)
          [path, rows.reduce(File.read(path)) { |text, row| replace_region(text, row, workflow) }]
        end
      end

      # @return [Array<Hash{String => String}>] the `CiShards` rows
      # @raise [SystemExit] when a row's `count` is not a positive whole number
      def shards
        Hecks::Vocabulary.rows("CiShards").each do |row|
          abort "ci_shards: #{row["name"]} has count #{row["count"].inspect}" unless row["count"].to_s.match?(/\A[1-9][0-9]*\z/)
        end
      end

      # @param stale [Array<String>] absolute paths whose text differs from the rows
      # @param root [String] the checkout
      # @return [Integer] 0 when current, else 1 with the stale workflows on stderr
      def report(stale, root)
        if stale.empty?
          puts "ci_shards: #{shards.size} sharded jobs, every region current"
          return 0
        end

        warn "ci_shards: out of date: #{stale.map { |path| path.delete_prefix("#{root}/") }.join(", ")} " \
             "(run hecks project_ci_shards)"
        1
      end

      # @param text [String] a workflow
      # @param row [Hash{String => String}] a `CiShards` row
      # @param workflow [String] the workflow's file name, for the refusal
      # @return [String] the workflow with the job's marked region replaced by its strategy
      def replace_region(text, row, workflow)
        name = row.fetch("name")
        region = /^    # BEGIN GENERATED ci_shards #{Regexp.escape(name)}\b.*?^    # END GENERATED ci_shards #{Regexp.escape(name)}$/m
        abort "ci_shards: #{workflow} has no BEGIN/END GENERATED ci_shards #{name} region" unless text.match?(region)

        text.sub(region) { strategy(row) }
      end

      # @param row [Hash{String => String}] a `CiShards` row
      # @return [String] the marked region: the job's `strategy:` with its matrix of groups
      def strategy(row)
        name = row.fetch("name")
        groups = (1..Integer(row.fetch("count"))).to_a.join(", ")
        ["    # BEGIN GENERATED ci_shards #{name} (CiShards vocabulary; hecks project_ci_shards). Do not hand-edit.",
         "    strategy:",
         "      # A regression in one shard should not cancel the others.",
         "      fail-fast: false",
         "      matrix:",
         "        group: [#{groups}]",
         "    # END GENERATED ci_shards #{name}"].join("\n")
      end
    end
  end
end
