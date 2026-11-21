# frozen_string_literal: true

require_relative "rest_pull_view"

# Seeds MainIntegration runs by their landed sha and stands GitHub in for a train pull request
# closed unmerged, whose branch is named for a later commit than the run's.
module ClosedTrainRuns
  CLOSED_TRAIN = { number: 1489, state: "CLOSED", mergeCommit: nil, comments: [],
                   headRefName: "train/main-7a4545d7de76", commits: [] }.freeze

  def saga = @hecks.registry.saga_instances["MainIntegration"]

  def runs = Hecks::Adapters::MainIntegration::Runs.new(@hecks.registry)

  def seed(sha, state)
    saga[sha] = { state: state, memory: { landed: { value: sha } }, completed_compensations: [] }
  end

  def stand_in_closed_train(sha)
    pull = CLOSED_TRAIN.merge(commits: [{ "oid" => sha, "messageHeadline" => "landed" }])
    Hecks::Adapters::CiRuns::PullCache.shared.clear
    Hecks::Adapters::CiRuns.runner = ->(argv, **) { [true, RestPullView.answer(argv, pull)] }
  end

  def observe = Hecks::Adapters::MainIntegration.new(registry: @hecks.registry).tend
end
