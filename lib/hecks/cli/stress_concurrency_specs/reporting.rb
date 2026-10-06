require "fileutils"

module Hecks
  module CLI
    module StressConcurrencySpecs
      # The verdict of a stress run: the clean line, or each failing run's saved log and how to
      # reproduce it. `StressConcurrencySpecs` extends it.
      module Reporting
        # @param root [String] the checkout; failing runs' output is saved under its `tmp/`
        # @param results [Array<Hash>] every run's result
        # @param out [IO] where the verdict goes
        # @return [Integer] 0 when every run passed, else 1
        def report(root, results, out)
          failures = results.reject { |r| r[:success] }
          if failures.empty?
            out.puts "CLEAN — #{results.size}/#{results.size} runs passed. " \
                     "No new flakiness beyond a single ordinary `rspec` run found in this many tries."
            return 0
          end

          out.puts "FOUND FLAKINESS — #{failures.size}/#{results.size} runs failed:"
          failures.each { |failure| save_failure(root, failure, out) }
          out.puts
          1
        end

        # Saves a failing run's full output and says where it went and how to reproduce it.
        #
        # @param root [String] the checkout; the log goes under its `tmp/stress-failures/`
        # @param failure [Hash] a failed run's result
        # @param out [IO] where the pointer goes
        # @return [void]
        def save_failure(root, failure, out)
          dir = File.join(root, "tmp/stress-failures")
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{failure[:label].tr(" ", "_").gsub(/[()]/, "")}-seed#{failure[:seed]}.log")
          File.write(path, failure[:output])
          out.puts "  [#{failure[:label]}] seed #{failure[:seed]} — output saved to #{path.sub("#{root}/", "")}"
          out.puts "    reproduce: #{failure[:reproduce]}"
        end
      end
    end
  end
end
