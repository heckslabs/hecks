# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Tools
    module Lanes
      # The files the `Lane` rows project into a checkout: a ruleset for each guarded lane and the
      # promotion workflow. It writes them, or with `check` compares them and writes nothing.
      class Files
        # @param root [String] the checkout
        def initialize(root)
          @root = root
        end

        # @return [Hash{String => String}] each file's absolute path to the text it should hold
        def projection
          rulesets.merge(workflow(Lanes::WORKFLOW, "follows") { |lanes| Lanes.workflow(lanes) })
                  .merge(workflow(Lanes::WATCH_WORKFLOW, "alert_after") { |lanes| WatchWorkflow.text(lanes) })
        end

        # @param files [Hash{String => String}] the projection
        # @return [Array<String>] ruleset files that no row of a guarded lane accounts for
        def leftover(files)
          Dir[File.join(@root, Lanes::RULESETS, "*.json")].reject { |path| files.key?(path) }
        end

        # @param check [Boolean] whether to only compare
        # @return [Integer] 0, or 1 when `check` finds a file out of date
        def run(check)
          files = projection
          stale = files.reject { |path, text| File.exist?(path) && File.read(path) == text }.keys
          extra = leftover(files)
          return report(stale + extra, files.size) if check

          write(files, stale, extra)
          0
        end

        private

        def rulesets
          Lanes.rulesets.to_h { |name, ruleset| [ruleset_path(name), "#{JSON.pretty_generate(ruleset)}\n"] }
        end

        # The workflow at `path` for the lanes whose `column` is set, or no file if none is.
        def workflow(path, column)
          lanes = Lanes.lanes.reject { |lane| lane[column].to_s.empty? }
          lanes.empty? ? {} : { File.join(@root, path) => yield(lanes) }
        end

        def ruleset_path(name) = File.join(@root, Lanes::RULESETS, "#{name}.json")

        def write(files, stale, extra)
          stale.each do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, files.fetch(path))
          end
          extra.each { |path| File.delete(path) }
          (stale + extra).each { |path| puts "wrote #{relative(path)}" }
          puts "lanes: #{Lanes.lanes.size} lanes, every file current" if (stale + extra).empty?
        end

        def report(out_of_date, count)
          if out_of_date.empty?
            puts "lanes: #{count} files, every one current"
            return 0
          end

          warn "lanes: out of date: #{out_of_date.map { |path| relative(path) }.join(", ")} " \
               "(run hecks regeneration_run.project_lanes)"
          1
        end

        def relative(path) = path.delete_prefix("#{@root}/")
      end
    end
  end
end
