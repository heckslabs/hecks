# frozen_string_literal: true

require "fileutils"
require "optparse"
require_relative "../../tools"

module Hecks
  module Tools
    module SiteRoutes
      # The command line of `project_site`: reading the flags, writing the stale files and saying
      # what was done.
      module Cli
        # The flags that take a value, by the keyword of `projection` each one sets.
        VALUE_FLAGS = {
          out: "--out=DIR", template: "--template=FILE", cms: "--cms=DIR", root_dir: "--root=DIR",
          extension: "--extension=EXT"
        }.freeze

        # @param argv [Array<String>] the command line, consumed down to the project directory
        # @return [Array(Hash, Boolean)] the keywords for `projection`, and whether `--check` was
        #   given
        def parse_flags(argv)
          options = {}
          check = false
          OptionParser.new do |parser|
            VALUE_FLAGS.each { |key, flag| parser.on(flag) { |value| options[key] = value } }
            parser.on("--check") { check = true }
          end.parse!(argv)
          [options, check]
        end

        # @param files [Hash{String => String}] each file's absolute path to the text it should hold
        # @return [Array<String>] the paths whose file is missing or holds other text
        def stale_paths(files)
          files.reject { |path, text| File.file?(path) && File.read(path) == text }.keys
        end

        # Writes each stale file and prints a line for it.
        def write_stale(files, stale, project)
          stale.each do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, files.fetch(path))
            puts "wrote #{display(path, project)}"
          end
          puts "project_site: #{files.size} #{files.size == 1 ? "file" : "files"}, current" if stale.empty?
        end

        # @param stale [Array<String>] absolute paths whose text differs from the table
        # @param project [String] the project directory
        # @param check [Boolean] whether this is a `--check` run
        # @return [Integer] 0 when current, else 1 with the stale files on stderr
        def report(stale, project, _check)
          if stale.empty?
            puts "project_site: every file current"
            return 0
          end

          warn "project_site: out of date: #{stale.map { |path| display(path, project) }.join(", ")} " \
               "(run hecks site site_projection.project_site)"
          1
        end

        # @param path [String] an absolute path
        # @param project [String] the project directory
        # @return [String] the path relative to the project when it lies beneath it
        def display(path, project) = path.delete_prefix("#{project}/")
      end
    end
  end
end
