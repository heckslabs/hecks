# frozen_string_literal: true

# The switch of the red drill: whether the drill spec is defined, and so fails, in this run.
#
# The switch is on when `HECKS_RED_DRILL` is `1` in the environment, or when the checkout holds
# the tracked file `spec/support/red_drill.on` reading `1`. The file is per commit, not per
# pull request: a train pull request carries the boarded commit's tree, so a commit that holds the
# file turns the drill on for that commit's pull request and for the CI run of `main` there.
module RedDrill
  # The file that turns the drill on for the commit that holds it, relative to a checkout.
  FILE = File.join("spec", "support", "red_drill.on")

  # @param env [#[]] the environment to read
  # @param root [String] the checkout to look in
  # @return [Boolean] whether the drill is on
  def self.on?(env: ENV, root: File.expand_path("../..", __dir__))
    return true if env["HECKS_RED_DRILL"] == "1"

    path = File.join(root, FILE)
    File.file?(path) && File.read(path).strip == "1"
  end
end
