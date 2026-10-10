# frozen_string_literal: true

require "yaml"
require_relative "tree"
require_relative "../shell"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `InspectionRun` asks of the working tree: ranking its Ruby by complexity
      # (flog), finding copied code (flay), listing design smells (reek), and writing the combined
      # report with git churn (rubycritic).
      #
      # The tools take no exclude list of their own, so the files are listed here first and the
      # ones `.rubocop.yml` excludes (generated output, vendored code) are left out: a finding in
      # one belongs to its generator. Each tool then runs from the checkout's root through
      # `bundle exec`, and what it printed is the report.
      module Inspection
        # Every operation this family carries out, one for each tool.
        OPERATIONS = %w[flog flay reek rubycritic].freeze

        # The program and flags each operation starts, before the files.
        PROGRAMS = { "flog"       => %w[flog --methods-only],
                     "flay"       => %w[flay],
                     "reek"       => %w[reek],
                     "rubycritic" => %w[rubycritic --no-browser] }.freeze

        # The statuses that still mean the tool reported: reek ends 2 when it found smells.
        REPORTING = { "reek" => [0, 2] }.freeze

        # Searched when no path is named.
        DEFAULT_PATHS = "lib"

        module_function

        # Carries out one operation.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `InspectionRun` record's fields: `paths` and `top`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] starts the tool; a `Shell` when nil
        # @return [String] what the tool printed, cut to `top` lines when that is named
        # @raise [ConsoleCapture::Failure] when no Ruby file is named, or the tool is missing
        #   or fails
        def call(operation, held, tree, shell: nil)
          args = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          files = ruby_files(tree, args[:paths] || DEFAULT_PATHS)
          raise ConsoleCapture::Failure, "no Ruby file under #{args[:paths] || DEFAULT_PATHS}" if files.empty?

          result = (shell || Shell.new).capture("bundle", "exec", *PROGRAMS.fetch(operation), *files,
                                                chdir: tree.root)
          shorten(report(operation, result), args[:top])
        end

        # @param operation [String] the tool's name
        # @param result [Shell::Result] what the tool said
        # @return [String] its output
        # @raise [ConsoleCapture::Failure] when it ended in a status that is not a report
        def report(operation, result)
          return result.out if REPORTING.fetch(operation, [0]).include?(result.status.exitstatus)

          raise ConsoleCapture::Failure,
                "#{operation} ended with status #{result.status.exitstatus}: #{result.err}#{result.out}".strip
        end

        # @param text [String] a report
        # @param top [Integer, nil] how many lines to keep
        # @return [String] the first `top` lines, or the whole text
        def shorten(text, top)
          top ? text.lines.first(top).join : text
        end

        # The Ruby files under the named paths, less those the style config excludes.
        #
        # @param tree [Tree] the checkout
        # @param paths [String] comma-separated files or directories, relative to the root
        # @return [Array<String>] the files, relative to the root and sorted
        def ruby_files(tree, paths)
          excluded = exclusions(tree)
          paths.split(",").flat_map { |path| listing(tree, path) }.uniq.sort.reject do |file|
            excluded.any? { |glob| File.fnmatch?(glob, file, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
          end
        end

        # @return [Array<String>] the files at one path: itself when a file, else every `.rb` below
        def listing(tree, path)
          return [path] if File.file?(tree.path(path))

          Dir.glob("#{path}/**/*.rb", base: tree.root)
        end

        # @return [Array<String>] the globs `.rubocop.yml` excludes from every cop
        def exclusions(tree)
          config = YAML.safe_load_file(tree.path(".rubocop.yml"), permitted_classes: [Symbol])
          Array(config.dig("AllCops", "Exclude"))
        end
      end
    end
  end
end
