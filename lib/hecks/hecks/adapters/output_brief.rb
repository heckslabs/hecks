# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "output_brief/spec_summary"

module Hecks
  module Adapters
    # A spec run's long output, filed: the full text goes to a file and the answer is a short
    # summary that names it.
    #
    # A session reads every answer again on each later turn, so a run that prints hundreds of lines
    # costs far more than the read that needed them. The reader is the session that ran the
    # command, so the file lives under its job directory (`$CLAUDE_JOB_DIR/tmp/hecks-output`), or
    # under the system's temporary directory when there is no job. The text is answered in full
    # where a file would not serve: in CI, whose log is the only record, when `HECKS_OUTPUT=full`
    # asks for it, and whenever the file cannot be written, so a summary never loses the record.
    class OutputBrief
      # Every size this adapter and its summary decide by, in one place.
      #
      # `lines` and `characters` are the most a text may hold and still be answered whole;
      # `frames` is how many backtrace lines the first failure keeps and `block` how many lines of
      # it in all; `head` is how many opening lines stand in for a failure block when the runner
      # printed none; `errors` is how many failed examples list their first error line; `kept_days`
      # is how long a filed text is kept before a later filing removes it.
      LIMITS = { lines: 40, characters: 4000, frames: 5, block: 30, head: 15, errors: 20, kept_days: 7 }.freeze

      # The variable that asks for every text in full when it is `full`.
      WHOLE = "HECKS_OUTPUT"

      # The variable naming the directory of the job a session runs as.
      JOB = "CLAUDE_JOB_DIR"

      # The variables a CI runner sets, as `Codebase::TestScope` reads them.
      CI = %w[CI GITHUB_ACTIONS].freeze

      # @param text [String] what a run printed
      # @param label [String] what ran, which names the file
      # @return [String] the text, or its summary with the path of the file that holds it
      def self.of(text, label:) = new.call(text, label: label)

      # @param env [Hash{String => String}] the environment read for the job, CI and `WHOLE`
      # @param clock [#now] tells the time a file is named by and aged against
      def initialize(env: ENV, clock: Time)
        @env = env
        @clock = clock
      end

      # @param text [String] what a run printed
      # @param label [String] what ran, which names the file
      # @return [String] the text when it is short or must stay whole, else its summary
      def call(text, label:)
        return text if short?(text) || whole?

        path = filed(text, label)
        path ? SpecSummary.new(text, path, LIMITS).to_s : text
      end

      # @return [String] the directory the full texts are written to
      def directory
        job = @env[JOB].to_s
        File.join(job.empty? ? Dir.tmpdir : File.join(job, "tmp"), "hecks-output")
      end

      private

      def short?(text) = text.lines.size <= LIMITS[:lines] && text.size <= LIMITS[:characters]

      def whole? = @env[WHOLE] == "full" || CI.any? { |name| !["", "false"].include?(@env[name].to_s) }

      # The path the text was written to, or nil when it could not be written.
      def filed(text, label)
        FileUtils.mkdir_p(directory)
        prune
        path = File.join(directory, "#{label}-#{@clock.now.utc.strftime("%Y%m%dT%H%M%S%LZ")}-#{Process.pid}.log")
        File.write(path, text)
        path
      rescue SystemCallError
        nil
      end

      # Removes the filed texts older than `kept_days`, so the directory does not grow without end.
      def prune
        oldest = @clock.now - (LIMITS[:kept_days] * 86_400)
        Dir.glob(File.join(directory, "*.log")).each do |path|
          FileUtils.rm_f(path) if File.mtime(path) < oldest
        end
      end
    end
  end
end
