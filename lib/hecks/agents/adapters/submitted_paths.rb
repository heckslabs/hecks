# frozen_string_literal: true

require "open3"
require_relative "submitted_paths/review_tiering"
require_relative "submitted_paths/domain_owners"

module Hecks
  module Adapters
    # The `SubmittedPaths` port's adapter for `ChangeReview`: reads the paths a submitted commit
    # changed against main, and the commit's tree, in the checkout it was submitted from; and the
    # diff of its design files, from the primary checkout, for the architect.
    #
    # It runs `git diff --name-only main...<commit>` and `git rev-parse <commit>^{tree}` with an
    # argument list, never a shell, and judges nothing: which paths ask for the architect is the
    # bluebook's given. Each path is answered between bars (`|a.bluebook|b.rb|`), so a given
    # matches a path whole. It answers the `Tier` and `Domains` queries from one more read of the
    # diff, `--name-status -M100%`, so a pure rename shows both its ends; `ReviewTiering` and
    # `DomainOwners` match the paths to the aggregate's rows.
    class SubmittedPaths
      # The checkout or the commit could not be read; the message is git's own.
      class Unread < StandardError; end

      BLUEBOOK_DIR = File.expand_path("..", __dir__)

      # Git's pathspecs for what a change review judges: the design files and the decision records.
      DESIGN = %w[*.bluebook *.hecksagon *.behaviors *.world docs/decisions/].freeze

      # A bluebook's path: the domains of these are what a model check of the commit runs on.
      BLUEBOOK = /\.bluebook\z/

      # @param git [#call, nil] stand-in: takes the argv, answers `[stdout, stderr, status]`
      # @param rows [#call, nil] stand-in: takes a value object's name, answers its rows
      def initialize(git: nil, rows: nil)
        @git = git || ->(argv) { Open3.capture3(*argv) }
        @rows = rows || method(:bluebook_rows)
      end

      # @param review [Hash, String] the submitted commit
      # @param checkout [Hash, String] the directory it was submitted from
      # @return [Hash{Symbol => Hash}] `paths:` the changed paths, each between bars, and `tree:`
      #   the commit's tree
      # @raise [Unread] naming why git could not read them
      def submitted_paths(review:, checkout:, **)
        commit = plain(review)
        dir = plain(checkout)
        listing = read(commit, dir, "diff", "--name-only", "main...#{commit}")
        { paths: { value: barred(listing) }, tree: { value: read(commit, dir, "rev-parse", "#{commit}^{tree}").strip } }
      end

      # @param review [Hash, String] the submitted commit
      # @param checkout [Hash, String] the directory it was submitted from
      # @param regenerated [Hash, String, nil] `same` when the landing's generated check passed
      # @return [Hash{Symbol => String}] `text:` the tier, then each path with its tier and class
      # @raise [Unread] naming why git could not read the paths
      def tier(review:, checkout:, regenerated: nil, **)
        tiering = ReviewTiering.new(tiers: @rows.call("ReviewTier"), words: @rows.call("SecurityWord"))
        { text: tiering.answer(changes(plain(review), plain(checkout)), plain(regenerated)) }
      end

      # @param review [Hash, String] the submitted commit
      # @param checkout [Hash, String] the directory it was submitted from
      # @return [Hash{Symbol => String}] `text:` one domain directory per line
      # @raise [Unread] naming why git could not read the paths
      def domains(review:, checkout:, **)
        dir = plain(checkout)
        { text: owners(dir).answer(changes(plain(review), dir).map(&:first)) }
      end

      # The scope `SubmissionReview` counts its evidence against: the tier and the touched domains
      # from the same rows as {#tier} and {#domains}, and the domains of the changed bluebooks.
      #
      # @param submission [Hash, String] the submitted commit
      # @param checkout [Hash, String] the directory it was submitted from
      # @return [Hash{Symbol => Hash}] `tier:`, and `domains:` and `bluebooks:` each between bars
      # @raise [Unread] naming why git could not read the paths
      def read_scope(submission:, checkout:, **)
        commit = plain(submission)
        dir = plain(checkout)
        paths = changes(commit, dir).map(&:first)
        { tier:      { value: first_line(tier(review: commit, checkout: dir)[:text]) },
          domains:   { value: barred(owners(dir).answer(paths)) },
          bluebooks: { value: barred(owners(dir).answer(paths.grep(BLUEBOOK))) } }
      end

      # @param review [Hash, String] the submitted commit
      # @return [Hash{Symbol => String}] `text:` git's diff of the commit's design files against
      #   main
      # @raise [Unread] naming why git could not read the commit
      def diff(review:, **)
        commit = plain(review)
        { text: read(commit, primary, "diff", "main...#{commit}", "--", *DESIGN) }
      end

      private

      # The primary checkout: the parent of the repository's common git directory, which every
      # linked worktree shares and which outlives them.
      def primary
        File.dirname(read("main", BLUEBOOK_DIR, "rev-parse", "--path-format=absolute", "--git-common-dir").strip)
      end

      def read(commit, dir, *args)
        out, err, status = @git.call(["git", "-C", dir, *args])
        raise Unread, "git could not read the paths #{commit} changed: #{err.strip}" unless status.success?

        out
      end

      # Each changed path, and whether it is an end of a rename git found at 100%.
      def changes(commit, dir)
        read(commit, dir, "diff", "--name-status", "-M100%", "main...#{commit}").lines.flat_map do |line|
          status, *paths = line.chomp.split("\t")
          paths.map { |path| [path, status.to_s.start_with?("R100")] }
        end
      end

      def owners(dir) = DomainOwners.new(rows: @rows.call("DomainPath"), root: dir)

      # The tier a `Tier` answer names on its first line.
      def first_line(text)
        line = text.each_line.first
        line.to_s.strip
      end

      # Each path of git's listing between bars: `|a.bluebook|b.rb|`.
      def barred(listing)
        paths = listing.lines.map(&:strip).reject(&:empty?)
        "|#{paths.join("|")}|"
      end

      def bluebook_rows(table)
        aggregate = agents_bluebook.aggregates.find { |candidate| candidate.hecks_name == "ChangeReview" }
        aggregate.value_objects.find { |object| object.hecks_name == table }.members
      end

      def agents_bluebook = described.bluebooks.fetch("Agents")

      def described = Hecks.describe(BLUEBOOK_DIR).registry

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
