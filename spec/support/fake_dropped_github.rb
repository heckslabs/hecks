# frozen_string_literal: true

require_relative "fake_train_github"

# A scripted GitHub whose train pull request is open with every check green, as after the merge
# queue dropped it when main moved: `auto_merge` says whether GitHub still holds its auto-merge,
# `merge_state` what GitHub reports of its mergeability, and `merge_refusal` makes
# `gh pr merge` refuse. The calls it remembers are the ones that changed the pull request.
class FakeDroppedGithub < FakeTrainGithub
  attr_accessor :auto_merge, :merge_state, :merge_refusal

  def initialize
    super
    @rollup = [{ name: "ci", status: "COMPLETED", conclusion: "SUCCESS" }]
    @auto_merge = nil
    @merge_state = "clean"
  end

  # The `GithubPullRequests` runner, remembering each call as the `CiRuns` one does.
  def gh(argv)
    @calls << "gh #{argv.join(" ")}"
    return ["", @merge_refusal, false] if @merge_refusal && argv[0..1] == %w[pr merge]

    super
  end

  # @return [Array<String>] the `gh pr merge` calls made
  def merges = calls.grep(/pr merge/)

  private

  def answer(argv)
    return { mergeable_state: @merge_state }.to_json if argv.last.to_s.match?(%r{/pulls/\d+\z})

    super
  end

  def view = super.merge(autoMergeRequest: @auto_merge)
end
