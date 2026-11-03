# frozen_string_literal: true

require "hecks/vocabulary"
require "hecks/release/version_commit"

module Hecks
  module Release
    # Whether the commit that set the version carries the owner's approval of the release.
    #
    # Releases are the owner's decision. A bump on `main` reaches `stable` by itself, so the bump
    # commit must say, in its message, that a release is wanted: a trailer line named by the
    # `release_trailer` of the `Lane` row a release is cut from, `Release-Approved-By: <name>`. The
    # name must be one of the `ReleaseOwner` rows of the Vocabulary bluebook, the one list of who may
    # approve a release. Two ways round a missing trailer exist and are declared: a tag for the version
    # already standing (`PublishingRun.Accept`'s `tag_state`), and a by-hand run whose `approved_by`
    # names an owner. The decision is read from git history alone, so it can be made again on any later run. It reads
    # only the Vocabulary table, so `release.yml` can run it with the runner's own Ruby.
    module Approval
      # The key of a trailer line and the space after its colon: "Release-Approved-By: ".
      TRAILER_KEY = /\A[^:]*:\s*/

      module_function

      # @return [String] the trailer key, read from the `Lane` row that feeds a tag
      # @raise [KeyError] when that row names no trailer
      def trailer
        row = Hecks::Vocabulary.rows("Lane").find { |lane| !lane["feeds"].to_s.empty? }
        key = row && row["release_trailer"].to_s
        raise KeyError, "the Lane row a release is cut from names no release_trailer" if key.nil? || key.empty?

        key
      end

      # @param message [String] a commit message
      # @return [String, nil] who approved, from the first trailer line with a name, or nil
      def approver(message)
        line = stripped_lines(message).find { |text| text.match?(/\A#{Regexp.escape(trailer)}:\s*\S/) }
        line&.sub(TRAILER_KEY, "")
      end

      # @param message [String, nil] a commit message
      # @return [Array<String>] its lines, each stripped
      def stripped_lines(message) = message.to_s.lines.map(&:strip)

      # @param message [String] the message of the commit that set the version
      # @param tag_exists [Boolean] whether the release's tag already stands on origin: a release
      #   that was begun was approved when it began, so finishing it asks again for nothing
      # @param explicit [String, nil] a name the owner passed to a by-hand run
      # @return [Array(Boolean, String)] whether the release may go ahead, and the words to print
      def verdict(message:, tag_exists: false, explicit: nil)
        by_hand = explicit.to_s.strip
        return by_hand_verdict(by_hand) unless by_hand.empty?
        return [true, "the tag already stands; finishing a release that was begun"] if tag_exists

        who = approver(message)
        return [false, refusal_words(who)] unless owner?(who)

        [true, "approved by #{who} (#{trailer} trailer)"]
      end

      # @return [Array<String>] the names that may approve a release: the `ReleaseOwner` rows
      def owners = Hecks::Vocabulary.rows("ReleaseOwner").map { |row| row.fetch("name") }

      # @param name [String, nil] a name from a trailer or a by-hand run
      # @return [Boolean] whether it is one of the {owners}
      def owner?(name) = !name.nil? && owners.include?(name.strip)

      # @param message [String] the message of the commit that set the version
      # @return [Boolean] whether it carries the trailer, written by one of the {owners}
      def approved?(message) = owner?(approver(message))

      def by_hand_verdict(name)
        return [true, "approved by #{name} (by-hand run)"] if owner?(name)

        [false, "'#{name}' is not a release owner (#{owners.join(", ")}); a by-hand approval must name one"]
      end

      def refusal_words(who)
        cause = if who
                  "names '#{who}', who is not a release owner (#{owners.join(", ")})"
                else
                  "has no '#{trailer}: <name>' line in its message"
                end
        "the commit that set the version #{cause}, so it is not a release the owner asked for. " \
          "Nothing was tagged or pushed. To release it, re-run by hand with the approval: " \
          "gh workflow run release.yml -f tag=vX.Y.Z -f approved_by=<name>"
      end

      # Reads the decision's inputs from the environment `release.yml` gives it.
      #
      # @param env [#[]] `COMMIT_MESSAGE`, or `COMMIT` (the first-parent commit that set the
      #   version,
      #   whose message is read as {VersionCommit} reads it), `TAG_EXISTS` (true/false),
      #   `APPROVED_BY`
      # @param out [#puts] where the words go
      # @return [Integer] the exit status: 0 to go ahead, 1 to refuse
      def check(env: ENV, out: $stdout)
        ok, words = verdict(message:    env["COMMIT_MESSAGE"] || VersionCommit.message(env["COMMIT"].to_s),
                            tag_exists: env["TAG_EXISTS"] == "true",
                            explicit:   env["APPROVED_BY"])
        out.puts(ok ? "release approval: #{words}" : "::error::#{words}")
        ok ? 0 : 1
      end
    end
  end
end
