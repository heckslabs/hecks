# frozen_string_literal: true

module Hecks
  module Adapters
    # The work items a landed branch can name, as the `LandedWork` port and a settle's landing
    # reads both judge it.
    #
    # A branch names its work item by the whole branch name, or the name without QA's `qa/` prefix.
    # `LinkedTree.add!` puts `-<N>` after a name an earlier branch took, so `x-2` was cut for `x`;
    # the name without that suffix is a candidate only when no work item, of any status, carries the
    # whole name, so a real item named `x-2` is never read as `x`.
    module BranchWorkNames
      # The prefix QA puts on a branch whose work item carries the bare name.
      QA_PREFIX = "qa/"

      # What `LinkedTree.add!` appends to a branch name an earlier branch took.
      COLLISION_SUFFIX = /-\d+\z/

      # @param branch [String] a landed branch
      # @param keys [Array<String>] the key of every work item, whatever its status
      # @return [Array<String>] the keys the branch can name, most exact first
      def self.of(branch, keys)
        whole = [branch, branch.delete_prefix(QA_PREFIX)].reject(&:empty?).uniq
        return whole if whole.any? { |name| keys.include?(name) }

        (whole + whole.map { |name| name.sub(COLLISION_SUFFIX, "") }).reject(&:empty?).uniq
      end
    end
  end
end
