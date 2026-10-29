# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    module Codebase
      # The minitest files of a spec directory. RSpec does not run them, so each one runs in its own Ruby
      # process, and its run summary is reported beside the RSpec output.
      module MinitestRuns
        # The summary line minitest prints, such as "3 runs, 5 assertions".
        SUMMARY = /\d+ runs?, /

        module_function

        # @param tree [Tree] the folder whose specs are listed
        # @return [Array<String>] their paths, relative to the folder, sorted
        def files(tree)
          Dir.glob("#{TestSuite::SPEC_DIRECTORY}/**/*_test.rb", base: tree.root).sort
        end

        # Runs each file in its own Ruby process, from the folder, outside this process's bundle so the
        # folder's own gems are the ones it loads.
        #
        # @param tree [Tree] the folder the files run in
        # @param files [Array<String>] the minitest files
        # @return [Array<String>] one line per file: its path and its run summary
        # @raise [ConsoleCapture::Failure] with the output of the first file that fails
        def reports(tree, files)
          files.map do |file|
            out, status = unbundled { Open3.capture2e(RbConfig.ruby, file, chdir: tree.root) }
            raise ConsoleCapture::Failure, "#{file} failed\n#{out.strip}" unless status.success?

            "#{file}: #{summary(out)}"
          end
        end

        # @param out [String] what a minitest file printed
        # @return [String] its last run summary line, or nothing when it printed none
        def summary(out)
          matches = out.lines.grep(SUMMARY)
          matches.last.to_s.strip
        end

        # Runs the block without the bundle this process was started under, when Bundler is loaded.
        def unbundled(&)
          defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
        end
      end
    end
  end
end
