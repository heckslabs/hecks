# frozen_string_literal: true

require "json"
require "open3"
require "hecks/vocabulary"
require_relative "../tools"

module Hecks
  module Tools
    # Decides whether a commit is only a release bump on a base that is fully certified, so CI may
    # inherit the base's certification instead of running the suite again.
    #
    # The files a bump edits, and which of their lines it may change, are the `ReleaseFile` rows of
    # the Vocabulary chapter. A change is a release bump when it touches at least one file, every
    # file it touches is a row, and every line it adds or removes in a file matches that row's
    # `lines` pattern (an empty pattern admits any line). Whether the base is certified is read
    # from the base commit's own check runs: every `RequiredCheck` row that is not marked
    # `runs: always` must have its latest run on the base succeed or be skipped.
    #
    # Every case that cannot be confirmed answers "not a release bump", so the suite runs.
    module ReleaseOnly
      GREEN = %w[success skipped].freeze

      # The `+` or `-` that opens an added or removed line of a diff.
      CHANGE_MARK = /\A[+-]/

      module_function

      # @param changes [Hash{String => Array<String>}] each changed path to the lines it adds or
      #   removes
      # @param files [Array<Hash{String => String}>] the `ReleaseFile` rows
      # @return [Boolean] whether the change touches only release files, and only their release
      #   lines
      def release_only?(changes, files: Hecks::Vocabulary.rows("ReleaseFile"))
        return false if changes.empty?

        by_path = files.to_h { |row| [row.fetch("path"), row.fetch("lines", "")] }
        changes.all? { |path, lines| by_path.key?(path) && lines_allowed?(lines, by_path.fetch(path)) }
      end

      # @param lines [Array<String>] the changed lines of one file
      # @param pattern [String] the row's `lines` regex, empty for any line
      # @return [Boolean] whether every changed line matches
      def lines_allowed?(lines, pattern)
        return true if pattern.to_s.empty?

        regex = Regexp.new(pattern)
        lines.all? { |line| line.match?(regex) }
      end

      # @param runs [Array<Hash{String => String}>] the base commit's check runs: `name`,
      #   `conclusion` and `started_at`
      # @param required [Array<Hash{String => String}>] the `RequiredCheck` rows
      # @return [Boolean] whether every check that must be inherited has a green latest run
      def certified?(runs, required: Hecks::Vocabulary.rows("RequiredCheck"))
        latest = latest_runs(runs)
        inherited = required.reject { |row| row["runs"] == "always" }.map { |row| row.fetch("name") }
        inherited.all? { |name| GREEN.include?(latest[name].to_h["conclusion"]) }
      end

      # @return [Hash{String => Hash}] each check's most recently started run
      def latest_runs(runs)
        runs.group_by { |run| run["name"] }.transform_values { |group| group.max_by { |run| run["started_at"].to_s } }
      end

      # @param base [String] the commit the change is measured against
      # @param head [String] the commit under test
      # @param root [String] the checkout
      # @return [Hash{String => Array<String>}, nil] each changed path to its changed lines, or nil
      #   when git could not say
      def changes(base, head, root:)
        out, _err, status = Open3.capture3("git", "-C", root, "diff", "-U0", "--no-color", base, head)
        status.success? ? parse(out) : nil
      end

      # @param diff [String] `git diff -U0` output
      # @return [Hash{String => Array<String>}] each changed path to the lines it adds or removes
      def parse(diff)
        found = Hash.new { |hash, key| hash[key] = [] }
        path = nil
        diff.each_line do |line|
          path = file_of(line.chomp) || path
          found[path] << line[1..].chomp if path && content_line?(line)
        end
        found.to_h
      end

      # @return [String, nil] the path a `+++` or `---` header names, nil for any other line
      def file_of(line)
        return line.delete_prefix("+++ b/") if line.start_with?("+++ b/")

        line.delete_prefix("--- a/") if line.start_with?("--- a/")
      end

      # @return [Boolean] whether the line is an added or removed line, not a header
      def content_line?(line)
        line.match?(CHANGE_MARK) && !line.start_with?("+++ ", "--- ")
      end

      # @param repository [String] `owner/name`
      # @param sha [String] the commit whose check runs are read
      # @param env [Hash{String => String}] carries `GH_TOKEN` for the API call
      # @return [Array<Hash{String => String}>, nil] the check runs, or nil when the API failed
      def check_runs(repository, sha, env: ENV)
        path = "repos/#{repository}/commits/#{sha}/check-runs?per_page=100"
        jq = ".check_runs[] | {name, conclusion, started_at}"
        out, _err, status = Open3.capture3(env.to_h.slice("GH_TOKEN"), "gh", "api", path, "--paginate", "--jq", jq)
        status.success? ? out.lines.map { |line| JSON.parse(line) } : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
