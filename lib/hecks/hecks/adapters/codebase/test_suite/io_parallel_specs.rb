# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require_relative "../../console_capture"

module Hecks
  module Adapters
    module Codebase
      module TestSuite
        # The spec files with at least one example matching an RSpec tag filter, which ci.yml hands
        # to `parallel_rspec` instead of the whole `spec` directory; `TestSuiteRun` lists them,
        # checks the committed list against them and writes that list.
        #
        # Given every spec file, parallel_tests ignores the runtime log unless it covers about 67%
        # of them, so a tag-filtered job silently groups by file size. A dry run, not grep, picks
        # the files so inherited tags, `~fuzzing` and shared examples count.
        module IoParallelSpecs
          # One listing: the checkout, the exclude pattern and the RSpec tag arguments.
          Listing = Struct.new(:root, :exclude, :tags, keyword_init: true)

          module_function

          # @param listing [Listing] the checkout, exclude pattern and tag arguments
          # @return [Array<String>] the spec files that carry a matching example, sorted
          # @raise [ConsoleCapture::Failure] on no tags, no candidates, a failed dry run or no match
          def files(listing)
            refuse_untagged(listing.tags)
            candidates = candidate_files(listing)
            examples = dry_run_examples(candidates, listing)
            matched = examples.map { |e| e.fetch("file_path").delete_prefix("./") }.uniq.sort
            refuse_no_match(candidates, listing.tags) if matched.empty?
            matched
          end

          # Writes the list to a file under the checkout.
          #
          # @param listing [Listing] the checkout, exclude pattern and tag arguments
          # @param path [String] the list's path, relative to the checkout
          # @return [Array<String>] the files written
          def write(listing, path)
            files(listing).tap { |list| File.write(File.expand_path(path, listing.root), "#{list.join("\n")}\n") }
          end

          # Checks a committed list against the files that carry a matching example.
          #
          # @param listing [Listing] the checkout, exclude pattern and tag arguments
          # @param path [String] the committed list, relative to the checkout
          # @param matched [Array<String>] the files that carry a matching example
          # @return [Array<String>] `matched`, when the list holds exactly them
          # @raise [ConsoleCapture::Failure] naming what is missing and stale, and the refresh
          #   command
          def check(listing, path, matched = files(listing))
            full = File.expand_path(path, listing.root)
            committed = File.exist?(full) ? File.readlines(full, chomp: true).reject(&:empty?) : []
            missing = matched - committed
            stale = committed - matched
            return matched if missing.empty? && stale.empty?

            raise ConsoleCapture::Failure, stale_report(listing, path, missing, stale)
          end

          # @param listing [Listing] the checkout and exclude pattern
          # @return [Array<String>] the spec files left after the exclude pattern, sorted
          # @raise [ConsoleCapture::Failure] when there are none
          def candidate_files(listing)
            candidates = Dir.glob("spec/**/*_spec.rb", base: listing.root).grep_v(Regexp.new(listing.exclude.to_s)).sort
            return candidates unless candidates.empty?

            raise ConsoleCapture::Failure,
                  "found ZERO candidate spec files after applying the exclude pattern — that's almost certainly " \
                  "a broken pattern or an empty checkout. Refusing to hand parallel_rspec nothing to run."
          end

          # @param tags [Array<String>] the RSpec tag arguments
          # @return [void]
          # @raise [ConsoleCapture::Failure] when there are none
          def refuse_untagged(tags)
            return unless Array(tags).empty?

            raise ConsoleCapture::Failure, "a listing needs an RSpec tag filter (tags.value=\"--tag io\")"
          end

          # @param candidates [Array<String>] the files asked about
          # @param tags [Array<String>] the RSpec tag arguments
          # @return [void]
          # @raise [ConsoleCapture::Failure] always
          def refuse_no_match(candidates, tags)
            raise ConsoleCapture::Failure,
                  "#{candidates.size} candidate files, but the dry run matched ZERO examples under " \
                  "`#{tags.join(" ")}` — almost certainly a broken tag filter. Refusing to hand parallel_rspec nothing."
          end

          # @param candidates [Array<String>] the spec files to ask about
          # @param listing [Listing] the checkout and tag arguments
          # @return [Array<Hash>] the dry run's examples
          # @raise [ConsoleCapture::Failure] when the dry run fails or prints no JSON
          def dry_run_examples(candidates, listing)
            command = ["bundle", "exec", "rspec", "--dry-run", *listing.tags, "--format", "json", *candidates]
            stdout, stderr, status = Open3.capture3(*command, chdir: listing.root)
            raise ConsoleCapture::Failure, "#{stderr}\n`#{command.join(" ")}` exited #{status.exitstatus}" unless status.success?

            start = stdout.index('{"version"')
            raise ConsoleCapture::Failure, "no RSpec JSON in the dry run's stdout:\n#{stdout}" unless start

            JSON.parse(stdout[start..])["examples"] || []
          end

          # @param listing [Listing] the exclude pattern and tag arguments the run used
          # @param path [String] the committed list
          # @param missing [Array<String>] files that carry a matching example but are not listed
          # @param stale [Array<String>] files listed that carry none
          # @return [String] what is out of date and the command that rewrites the list
          def stale_report(listing, path, missing, stale)
            lines = ["#{path} is out of date."]
            if missing.any?
              lines << named("carries a matching example but is not listed (would never run in the shards)",
                             missing)
            end
            lines << named("listed but carries no matching example any more", stale) if stale.any?
            (lines << "Refresh it and commit the result:\n  #{refresh_command(listing, path)}").join("\n")
          end

          # @param listing [Listing] the exclude pattern and tag arguments the run used
          # @param path [String] the committed list
          # @return [String] the launcher command that rewrites the committed list
          def refresh_command(listing, path)
            args = { "exclude" => listing.exclude.to_s, "tags" => listing.tags.join(" "), "write" => path }
            words = args.map { |name, value| "#{name}.value=#{Shellwords.escape(value)}" }
            "exe/hecks test_suite_run.write_io_parallel_spec_list! #{words.join(" ")} --confirm"
          end

          # @param heading [String] what the paths have in common
          # @param paths [Array<String>] the paths
          # @return [String] the heading with the paths under it
          def named(heading, paths) = "  #{heading}:\n    #{paths.join("\n    ")}"
        end
      end
    end
  end
end
