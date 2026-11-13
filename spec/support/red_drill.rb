# frozen_string_literal: true

# The switch of the red drill: whether the drill spec is defined, and so fails, in this run.
#
# The switch is the environment alone: it is on when `HECKS_RED_DRILL` is `1`. In CI the rspec
# shards set it from the pull request's labels, `1` only on a pull request that carries the
# `red-drill` label, so the drill is per pull request and never per commit: the same tree is
# green on `main`, in the merge queue and on every unlabelled pull request, and raises no flag.
#
# A drill: board as usual, then `gh pr edit <number> --add-label red-drill` on that train pull
# request. The labelled run fails, the red path reruns it and files the `red-train-<pr>` work
# item; removing the label runs CI again, green, and auto-merge takes the pull request.
module RedDrill
  # The pull request label that turns the drill on for that pull request's CI runs.
  LABEL = "red-drill"

  # @param env [#[]] the environment to read
  # @return [Boolean] whether the drill is on
  def self.on?(env: ENV)
    env["HECKS_RED_DRILL"] == "1"
  end
end
