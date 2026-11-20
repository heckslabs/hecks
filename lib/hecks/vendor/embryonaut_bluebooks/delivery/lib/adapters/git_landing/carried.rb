# frozen_string_literal: true

require_relative "../git_main_pull/boarding"

module Hecks
  module Adapters
    class GitLanding
      # How a branch stands against the branch it was cut for: whether `onto` carries its commits,
      # by id, by patch or in a squash-merged train, and what a discard says it dropped.
      #
      # Mixed into `Tidy`, which supplies `@onto`, `@discarding`, `@checkout`, `@git`, `count`,
      # `ancestor?` and `read`.
      module Carried
        include GitMainPull::Boarding

        # The most commits a refusal names.
        LISTED = 5

        private

        def unmerged(tip)
          return "it has no commit to verify" unless tip
          return if @discarding

          local = "refs/heads/#{@onto}"
          return unless count("#{local}..#{tip}").positive? || !ancestor?(tip, local)

          lacking = lacking(tip)
          "it has #{lacking.size} commit(s) not on #{@onto}: #{listed(lacking)}" unless lacking.empty?
        end

        # The commits the branch adds that `onto` carries under no id, no patch and no train:
        # `git cherry` marks one `onto` has a patch-equivalent of with `-` and one it lacks with
        # `+`, and a `+` commit is still carried when a boarded commit of a train squashed onto
        # `onto` since the branch forked contains it (`Boarding` checks that commit's tree).
        #
        # @return [Array<String>] each lacking commit as "<sha> <subject>", oldest first
        def lacking(tip)
          local = "refs/heads/#{@onto}"
          added = cherry_added(local, tip)
          return added if added.empty?

          boarded = boardings("#{read("merge-base", local, tip, dir: @checkout)}..#{local}")
          added.reject { |line| boarded.any? { |sha| ancestor?(line.split(" ", 2).first, sha) } }
        end

        def cherry_added(local, tip)
          lines = read("cherry", "-v", local, tip, dir: @checkout).lines.select { |line| line.start_with?("+") }
          lines.map { |line| line.chomp.delete_prefix("+ ") }
        end

        def listed(lacking)
          shown = lacking.first(LISTED).map { |line| line.split(" ", 2).then { |sha, said| "#{sha[0, 9]} #{said}" } }.join(", ")
          lacking.size > LISTED ? "#{shown} and #{lacking.size - LISTED} more" : shown
        end

        # What a discard says it dropped, so the commits can be found again by their tip.
        def discarded_note(tip)
          return unless @discarding

          "it was at #{tip} with #{lacking(tip).size} commit(s) not on #{@onto}"
        end
      end
    end
  end
end
