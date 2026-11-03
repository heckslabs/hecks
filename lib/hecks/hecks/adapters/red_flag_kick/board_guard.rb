# frozen_string_literal: true

require_relative "restorer"
require_relative "../console_capture"

module Hecks
  module Adapters
    class RedFlagKick
      # Stands between a landed restore and the train: local main may go out only as the restore
      # alone (ahead of origin/main by exactly that commit), or as exactly the green tree. A commit
      # another session landed on local main must not ride out with the kick.
      class BoardGuard
        # @param git [Git] the adapter git runs through
        # @param checkout [String] a directory in the repository
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param green [String] the last green head of main
        # @return [void]
        # @raise [ConsoleCapture::Failure] when origin cannot be fetched or local main holds more
        def check!(green)
          fetched = git("fetch", "-q", "origin")
          raise ConsoleCapture::Failure, "cannot fetch origin before boarding: #{fetched.err.strip}" unless fetched.ok?

          ahead = out("rev-list", "--first-parent", "origin/main..main").split
          return if same_tree?(green) || only_the_restore?(ahead)

          raise ConsoleCapture::Failure, "local main is #{ahead.size} commits ahead of origin/main, not only the restore"
        end

        # @param green [String] a commit of main
        # @return [Boolean] whether local main's tree is that commit's tree
        def same_tree?(green) = out("rev-parse", "main^{tree}") == out("rev-parse", "#{green}^{tree}")

        private

        def only_the_restore?(ahead)
          ahead.size == 1 && out("log", "-1", "--format=%s", ahead.first).start_with?(Restorer::SUBJECT)
        end

        def git(*) = @git.capture(*, chdir: @checkout)

        def out(*) = git(*).out.strip
      end
    end
  end
end
