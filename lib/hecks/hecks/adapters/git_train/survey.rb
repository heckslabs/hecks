# frozen_string_literal: true

module Hecks
  module Adapters
    class GitTrain
      # What a survey finds: every git checkout directly under a directory whose default branch
      # holds commits its remote does not, with how far ahead and behind it stands and its newest
      # unpushed commit. Each checkout is fetched first, so the counts are against the remote as it
      # is now. A checkout without the remote has nowhere to push and is passed over; one whose
      # fetch fails is named as unreadable.
      class Survey
        # @param git [Git] the adapter every git call goes through
        # @param root [String] the directory whose children are surveyed
        # @param remote [String] the remote each checkout is compared with
        def initialize(git, root, remote:)
          @git = git
          @root = root
          @remote = remote
        end

        # @return [String] one line per checkout with unpushed commits, else a line saying none has
        def report
          lines = checkouts.filter_map { |dir| line_for(dir) }
          lines.empty? ? "nothing to push under #{@root}" : lines.join("\n")
        end

        private

        # The git checkouts directly under the root that have the remote, in name order.
        def checkouts = children.select { |dir| File.exist?(File.join(dir, ".git")) && remote?(dir) }

        def children = Dir.children(@root).sort.map { |name| File.join(@root, name) }

        def line_for(dir)
          return "#{File.basename(dir)}: unreadable (fetching #{@remote} failed)" unless fetched?(dir)

          branch = default_branch(dir)
          ahead = count(dir, "#{@remote}/#{branch}..#{branch}")
          return if ahead.to_i.zero?

          "#{File.basename(dir)} (#{branch}): #{ahead} ahead, #{count(dir, "#{branch}..#{@remote}/#{branch}")} behind " \
            "— newest #{git(dir, "log", "-1", "--format=%h %cr %an: %s", branch)}"
        end

        def remote?(dir) = @git.capture("remote", "get-url", @remote, chdir: dir).ok?

        def fetched?(dir) = @git.capture("fetch", "-q", @remote, chdir: dir).ok?

        def default_branch(dir)
          head = git(dir, "symbolic-ref", "--short", "refs/remotes/#{@remote}/HEAD")
          head.empty? ? "main" : head.delete_prefix("#{@remote}/")
        end

        def count(dir, range) = git(dir, "rev-list", "--count", range)

        def git(dir, *) = @git.capture(*, chdir: dir).out.strip
      end
    end
  end
end
