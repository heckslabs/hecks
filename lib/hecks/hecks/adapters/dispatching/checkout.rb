# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class Dispatching
      # Where the repository's own checkout is, found from any worktree of it.
      #
      # A session that starts work items works in the main checkout: the reviews, red flags and
      # run records are stored there, and a worktree belongs to one work item. A roll heard by a
      # worktree's process therefore names the main checkout, never its own directory.
      module Checkout
        # @param directory [String] any directory of the repository, a linked worktree included
        # @return [String] the main checkout's absolute path; `directory` itself when git cannot
        #   name one
        def self.main(directory)
          common = Shell.new.capture("git", "rev-parse", "--path-format=absolute", "--git-common-dir", chdir: directory)
          return directory unless common.ok?

          path = common.out.strip
          File.basename(path) == ".git" ? File.dirname(path) : path
        end
      end
    end
  end
end
