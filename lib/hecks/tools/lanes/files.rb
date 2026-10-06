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
          files = Lanes.lanes.select { |lane| lane["guarded"] == "yes" }.to_h { |lane| [ruleset_path(lane), ruleset(lane)] }
          promoted = Lanes.lanes.reject { |lane| lane["follows"].to_s.empty? }
          files[File.join(@root, Lanes::WORKFLOW)] = Lanes.workflow(promoted) unless promoted.empty?
          files
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

        def ruleset_path(lane) = File.join(@root, Lanes::RULESETS, "#{lane["name"]}.json")

        def ruleset(lane) = "#{JSON.pretty_generate(Lanes.ruleset(lane))}\n"

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
