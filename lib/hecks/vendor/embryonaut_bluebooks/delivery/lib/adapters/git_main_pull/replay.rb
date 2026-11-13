# frozen_string_literal: true

module Hecks
  module Adapters
    module GitMainPull
      # What a rebase needs beyond its arguments: a committer, because replaying commits writes new
      # ones, and an honest account of why it stopped.
      #
      # An includer is `GitMainPull`, which sets `@git`.
      module Replay
        private

        # The `-c` arguments that give git a committer when the repository and the machine name
        # none: the one that committed the tip of `dir`, so replayed commits stay with their people.
        #
        # @param dir [String] the checkout that will rebase
        # @return [Array<String>] empty when git already knows who is committing
        def replay_identity(dir)
          return [] if email_configured?(dir)

          name, email = @git.capture("log", "-1", "--format=%cn%n%ce", chdir: dir).out.split("\n")
          name && email ? ["-c", "user.name=#{name}", "-c", "user.email=#{email}"] : []
        end

        def email_configured?(dir)
          email = @git.capture("config", "user.email", chdir: dir).out
          !email.strip.empty?
        end

        # Abandons the rebase that `result` ended and says why it stopped: the files in conflict,
        # or, when none are, git's own words.
        #
        # @param dir [String] the checkout that rebased
        # @param result [Shell::Result] the failed rebase
        # @return [String] `conflicts in <files>` or `failed: <git's message>`
        def abandon_rebase(dir, result)
          files = @git.capture("diff", "--name-only", "--diff-filter=U", chdir: dir).out.split
          @git.capture("rebase", "--abort", chdir: dir)
          return "conflicts in #{files.join(", ")}" unless files.empty?

          "failed: #{[result.err, result.out].map(&:strip).reject(&:empty?).join(" ")}"
        end
      end
    end
  end
end
