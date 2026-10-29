# frozen_string_literal: true

require "hecks"
require "fileutils"
require_relative "../tools"
require_relative "../projections/ci_pipeline/workflows"

module Hecks
  module Tools
    # Projects the workflow rows of the CiWorkflows chapter into the workflow files under
    # `.github/workflows`: each `Workflow` row becomes one file, written whole from its rows
    # (`Projections::CiPipeline::Workflows`, the `:ci_workflows` projection).
    #
    #   hecks regeneration_run.project_ci_pipeline [--confirm]
    #
    # A workflow with no row is hand-written and left alone. With `--check` nothing is written: the
    # tool answers 1 and names each file that differs from its rows.
    module CiWorkflows
      # The directory of the chapter that declares the rows, which attaches the CiPipeline chapter.
      CHAPTER_DIRECTORY = File.expand_path("../ci_workflows", __dir__)

      # The directory `ports/` and `adapters/` live under, loaded before the rows are.
      LIB_HECKS = File.expand_path("..", __dir__)

      # What a hecksagon that binds a store loads first.
      WIRING = %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
                  adapters/driven/prism.adapter].freeze

      module_function

      # Projects the rows, writes what differs and prints a line for each file written.
      #
      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout the files are written under
      # @return [Integer] 0, or 1 when `--check` finds a file out of date
      # @raise [SystemExit] with the reason on stderr when the rows are refused
      def main(argv, root: Tools::ROOT)
        files = projection(root)
        stale = files.reject { |path, text| File.file?(path) && File.read(path) == text }.keys
        return report(stale, root) if argv.include?("--check")

        write(files, stale, root)
        0
      end

      # @param root [String] the checkout the files belong under
      # @return [Hash{String => String}] each workflow's absolute path to the text it should hold
      # @raise [SystemExit] when the rows are refused
      def projection(root)
        registry = registry_for
        chapter = Projections::CiPipeline::Table.chapter(registry)
        table = Projections::CiPipeline::Table.read(chapter, registry: registry)
        files = Projector.call(:ci_workflows, bluebook: chapter, options: { table: table })
        files.transform_keys { |path| File.join(root, path) }
      rescue Projections::CiPipeline::Table::Invalid => e
        abort "project_ci_pipeline: #{e.message}"
      end

      # Loads the chapter that declares the rows the way a deploy loads a project: the bluebooks,
      # then the hecksagons that attach the bluebooks they need.
      #
      # @return [Hecks::Runtime::Registry] the registry
      def registry_for
        registry = Hecks::Runtime::Registry.new(root: CHAPTER_DIRECTORY)
        Hecks.with_registry(registry) do
          WIRING.each { |file| Kernel.load(File.join(LIB_HECKS, file)) }
          Dir.glob(File.join(CHAPTER_DIRECTORY, "*.bluebook")).each { |file| Kernel.load(file) }
          Dir.glob(File.join(CHAPTER_DIRECTORY, "*.hecksagon")).each { |file| Kernel.load(file) }
        end
        registry
      end

      # Writes each stale file and prints a line for it.
      def write(files, stale, root)
        stale.each do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, files.fetch(path))
          puts "wrote #{path.delete_prefix("#{root}/")}"
        end
        puts "ci_pipeline: every workflow current" if stale.empty?
      end

      # @param stale [Array<String>] absolute paths whose text differs from the rows
      # @param root [String] the checkout
      # @return [Integer] 0 when current, else 1 with the stale workflows on stderr
      def report(stale, root)
        if stale.empty?
          puts "ci_pipeline: every workflow current"
          return 0
        end

        warn "ci_pipeline: out of date: #{stale.map { |path| path.delete_prefix("#{root}/") }.join(", ")} " \
             "(run hecks regeneration_run.project_ci_pipeline --confirm)"
        1
      end
    end
  end
end
