# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The checkout whose local overlays name the stores. A linked worktree has none, so its main
      # checkout is read instead. A worktree's `.git` is a file that points into the main
      # checkout's `.git`, so the answer is read from that file and no `git` is run to learn it.
      module OwnerRoot
        # What a linked worktree's `.git` file holds, with the main checkout's path.
        LINKED = %r{\Agitdir: (.+)/\.git/worktrees/}

        module_function

        # @param root [String] a checkout, main or linked
        # @return [String] the main checkout's path; `root` itself when it is the main checkout or
        #   its `.git` cannot be read
        def of(root)
          pointer = File.join(root, ".git")
          (File.file?(pointer) && File.read(pointer)[LINKED, 1]) || root
        rescue SystemCallError
          root
        end
      end
    end
  end
end
