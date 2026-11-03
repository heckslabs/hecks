# frozen_string_literal: true

module Hecks
  module Adapters
    class GitLanding
      # How a branch stands against the branch it was cut for: whether `onto` carries its commits,
      # by
      # id or by patch, and what a discard says it dropped.
      #
      # Mixed into `Tidy`, which supplies `@onto`, `@discarding`, `@checkout`, `count`, `ancestor?`
      # and
      # `read`.
      module Carried
        private

        def unmerged(tip)
          return "it has no commit to verify" unless tip
          return if @discarding

          local = "refs/heads/#{@onto}"
          return unless count("#{local}..#{tip}").positive? || !ancestor?(tip, local)

          lacking = unmatched(local, tip)
          "it has #{lacking} commit(s) not on #{@onto}" if lacking.positive?
        end

        # How many commits the branch adds that `onto` carries under no id and no patch: `git cherry`
        # marks one `onto` has a patch-equivalent of with `-`, and one it lacks with `+`.
        def unmatched(local, tip)
          read("cherry", local, tip, dir: @checkout).lines.count { |line| line.start_with?("+") }
        end

        # What a discard says it dropped, so the commits can be found again by their tip.
        def discarded_note(tip)
          return unless @discarding

          "it was at #{tip} with #{unmatched("refs/heads/#{@onto}", tip)} commit(s) not on #{@onto}"
        end
      end
    end
  end
end
