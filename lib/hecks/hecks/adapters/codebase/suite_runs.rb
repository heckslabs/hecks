# frozen_string_literal: true

require "open3"
require_relative "test_runner"
require_relative "changed_specs"

module Hecks
  module Adapters
    module Codebase
      # The folder's spec runs that are more than one RSpec call, or a run of their own: the
      # minitest files, which RSpec does not run, the specs a change maps to, and the concurrency
      # stress. `TestSuite` answers for them.
      module SuiteRuns
        # The line a minitest run ends with, such as "1 runs, 1 assertions".
        RUN_SUMMARY = /\d+ runs?, /

        module_function

        # The minitest files of the spec directory: RSpec does not run them, so each runs alone.
        #
        # @param tree [Tree] the folder whose specs are listed
        # @return [Array<String>] their paths, relative to the folder, sorted
        def minitest_files(tree)
          Dir.glob("#{TestSuite::SPEC_DIRECTORY}/**/*_test.rb", base: tree.root).sort
        end

        # Runs each minitest file in its own Ruby process, from the folder, outside this process's
        # bundle so the folder's own gems are the ones it loads.
        #
        # @param tree [Tree] the folder the files run in
        # @param files [Array<String>] the minitest files
        # @return [Array<String>] one line per file: its path and its run summary
        # @raise [ConsoleCapture::Failure] with the output of the first file that fails
        def minitest_reports(tree, files)
          files.map do |file|
            out, status = unbundled { Open3.capture2e(RbConfig.ruby, file, chdir: tree.root) }
            raise ConsoleCapture::Failure, "#{file} failed\n#{out.strip}" unless status.success?

            summary(file, out)
          end
        end

        # @param file [String] the minitest file
        # @param out [String] what the file printed
        # @return [String] the file's path and the line its run ended with
        def summary(file, out)
          last_run = out.lines.grep(RUN_SUMMARY).last
          "#{file}: #{last_run.to_s.strip}"
        end

        # Runs the block without the bundle this process was started under, when Bundler is loaded.
        def unbundled(&)
          defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
        end

        # Runs the specs the files changed since a git ref map to, by name. Says so and runs nothing
        # when no spec maps to a change, so an unmapped change never falls back to the whole suite.
        #
        # @param args [Hash] `base` (the ref, `origin/main` when absent), and the run's variables
        # @param tree [Tree] the folder whose changes are read
        # @return [String] what the runner printed, or that no spec maps to the changes
        # @raise [ConsoleCapture::Failure] when git cannot read the changes
        def changed(args, tree)
          base = args[:base] || "origin/main"
          files = changed_files(tree, base)
          specs = Dir.glob("#{TestSuite::SPEC_DIRECTORY}/**/*_spec.rb", base: tree.root).sort
          mapped = ChangedSpecs.call(files, specs)
          return "no spec maps to the #{files.size} changed file(s) since #{base}; nothing run" if mapped.empty?

          TestRunner.new(tree).run_paths(paths: mapped, env: TestSuite.spec_env(args), tags: args[:tags])
        end

        # The files that differ from the ref, tracked and untracked, relative to the folder.
        #
        # @param tree [Tree] the folder under git
        # @param base [String] the ref to compare against
        # @return [Array<String>] the changed files
        # @raise [ConsoleCapture::Failure] when git refuses, with what it said
        def changed_files(tree, base)
          diff, status = Open3.capture2e("git", "-C", tree.root, "diff", "--name-only", base, "--")
          raise ConsoleCapture::Failure, diff.strip unless status.success?

          untracked, = Open3.capture2("git", "-C", tree.root, "ls-files", "--others", "--exclude-standard")
          listed_paths(diff, untracked)
        end

        # The non-empty, distinct lines of git's listings.
        #
        # @param listings [Array<String>] what git printed, one path a line
        # @return [Array<String>] the paths
        def listed_paths(*listings)
          listings.flat_map { |text| text.lines.map(&:strip).reject(&:empty?) }.uniq
        end

        # Runs the concurrency stress specs, which are a spec run of their own.
        #
        # @param args [Hash] `runs`, `parallel` and `seed_start`
        # @param tree [Tree] the checkout
        # @return [String] what the stress run printed
        def stress(args, tree)
          TestSuite.answer { TestSuite.command("stress_concurrency_specs").call(stress_flags(args), root: tree.root) }
        end

        # @param args [Hash] `runs`, `parallel` and `seed_start`
        # @return [Array<String>] the script's flags for those that are named
        def stress_flags(args)
          { "--runs" => :runs, "--parallel" => :parallel, "--seed-start" => :seed_start }
            .filter_map { |flag, name| [flag, args[name].to_s] if args[name] }.flatten
        end
      end
    end
  end
end
