# frozen_string_literal: true

require_relative "../dispatching/checkout"

module Hecks
  module Adapters
    class GitTrain
      # Where a boarding stands: the checkout named, else the worktree holding the branch, which
      # is the main checkout for `main`. A boarding from a linked worktree therefore names no path,
      # and a path it does name overrides the resolution.
      #
      # An includer has `read`, `plain` and `branch_of`.
      module Standing
        private

        # @param held [Hash] the `SendTrain` record: `checkout` and `branch`, each perhaps absent
        # @return [String] the checkout's top level
        # @raise [ConsoleCapture::Failure] when a named checkout is not a directory or repository
        def standing(held)
          named = plain(held[:checkout])
          named ? toplevel(named) : Dispatching::Checkout.holding(branch_of(held), Dir.pwd)
        end

        def toplevel(dir)
          raise ConsoleCapture::Failure, "#{dir} is not a directory" unless File.directory?(dir)

          read("rev-parse", "--show-toplevel", dir: dir)
        end
      end
    end
  end
end
