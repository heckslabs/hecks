# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require_relative "../../../cache_dir"

module Hecks
  module Adapters
    class CiRuns
      # The facts of a red train pull request, kept once read. The beat is a new process every
      # minute, so a failure read from a settled CI run (its failed jobs and their logs) would be
      # read again by every beat until the pull request is dealt with; here it is read once.
      #
      # The key is the failed checks' own links, which name the run and the job. A rerun starts new
      # jobs with new links, so a rerun reads the facts again; a pull request whose checks carry no
      # run link is never kept. The file is best-effort: one that cannot be read is a miss and one
      # that cannot be written is skipped.
      class SettledFacts
        RUN_LINK = %r{/actions/runs/\d+}

        # A kept file older than this many seconds is removed when a new one is written.
        KEEP_SECONDS = 86_400

        # @return [String] where the facts are kept: under `HECKS_CACHE_DIR` when named
        def self.dir
          named = ENV["HECKS_CACHE_DIR"].to_s
          named.empty? ? Hecks::CacheDir.path("ci_runs") : File.join(named, "ci_runs")
        end

        # @param pull [Hash] the pull request as `PullRequest#read` answers it
        # @param landed [String] the boarded commit
        # @param label [String] what is kept, so two things kept for one pull request stay apart
        # @param symbolize [Boolean] whether the kept hashes come back with symbol keys
        # @param dir [String] where the facts are kept
        def initialize(pull, landed, label: "failure", symbolize: true, dir: self.class.dir)
          @pull = pull
          @landed = landed
          @label = label
          @symbolize = symbolize
          @dir = dir
        end

        # @yieldreturn [Object, nil] what is kept, read when none is kept for these checks; nil is
        #   not kept (a read that failed)
        # @return [Object, nil] what was kept, or what was just read
        def fetch
          return yield unless key

          kept || yield.tap { |facts| keep(facts) unless facts.nil? }
        end

        private

        def key
          links = Array(@pull["statusCheckRollup"]).filter_map { |entry| link(entry) }
          return if links.empty?

          Digest::SHA256.hexdigest([@label, @landed, @pull["number"], links.sort].join("|"))[0, 24]
        end

        def link(entry)
          url = entry.fetch("detailsUrl") { entry["targetUrl"] }.to_s
          "#{url} #{entry.fetch("conclusion") { entry["state"] }}" if url.match?(RUN_LINK)
        end

        def path = File.join(@dir, "facts-#{key}.json")

        def kept
          JSON.parse(File.read(path), symbolize_names: @symbolize)
        rescue SystemCallError, JSON::ParserError
          nil
        end

        def keep(facts)
          FileUtils.mkdir_p(@dir)
          prune
          File.write("#{path}.#{Process.pid}", JSON.generate(facts))
          File.rename("#{path}.#{Process.pid}", path)
        rescue SystemCallError
          nil
        end

        def prune
          Dir.glob(File.join(@dir, "facts-*.json")).each do |file|
            File.delete(file) if File.mtime(file) < Time.now - KEEP_SECONDS
          end
        end
      end
    end
  end
end
