# frozen_string_literal: true

module Hecks
  module Adapters
    class BranchPruning
      # The early-CI mirror branches kept locally: `ci/<branch>` and `<branch>-<40 hex sha>`. A
      # mirror is a copy of a source branch, so it is deletable once that source is gone from
      # the local branches. Only local branches are read; a remote `ci/` mirror stays.
      module Mirrors
        SHA_SUFFIX = /-\h{40}\z/
        CI_PREFIX = "ci/"

        module_function

        # @param branch [String] a local branch
        # @return [String, nil] the branch it mirrors, nil when it is not a mirror
        def source(branch)
          return branch.delete_prefix(CI_PREFIX).sub(SHA_SUFFIX, "") if branch.start_with?(CI_PREFIX)

          branch.sub(SHA_SUFFIX, "") if branch.match?(SHA_SUFFIX)
        end
      end
    end
  end
end
