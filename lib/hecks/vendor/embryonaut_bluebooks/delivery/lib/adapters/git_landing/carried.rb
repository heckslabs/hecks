# frozen_string_literal: true

module Hecks
  module Adapters
    class GitLanding
      # How a branch stands against the branch it was cut for: whether `onto` carries its commits,
      # by id or by patch, and what a discard says it dropped.
      #
      # Mixed into `Tidy`, which supplies `@onto`, `@discarding`, `@checkout`, `@git`, `count`,
      # `ancestor?` and `read`.
      module Carried
        # The most commits a refusal names.
        LISTED = 5

        private

        def discard_hint = @retiring ? " (Landing.discard! removes a worktree whose commits #{@onto} lacks)" : ""

        def unmerged(tip)
          return "it has no commit to verify" unless tip
          return if @discarding

          local = "refs/heads/#{@onto}"
          return unless count("#{local}..#{tip}").positive? || !ancestor?(tip, local)

          lacking = lacking(tip)
          "it has #{lacking.size} commit(s) not on #{@onto}: #{listed(lacking)}#{discard_hint}" unless lacking.empty?
        end

        # The commits the branch adds that `onto` carries under no id and no patch: `git cherry`
        # marks one `onto` has a patch-equivalent of with `-` and one it lacks with `+`.
        #
        # @return [Array<String>] each lacking commit as "<sha> <subject>", oldest first
        def lacking(tip) = cherry_added("refs/heads/#{@onto}", tip)

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
