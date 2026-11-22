# frozen_string_literal: true

require "json"

# A stand-in for `gh api` over one commit's check runs: it answers every `RequiredCheck` green,
# after rate limiting the first `limited` reads of the check runs. It records the paths it was asked.
class StandInGithub
  GITHUB_ACTIONS = 15_368

  # @return [Array<String>] every path asked, in order
  attr_reader :paths

  # @param limited [Integer] how many reads of check runs are answered rate limited
  def initialize(limited)
    @limited = limited
    @paths = []
  end

  # @param path [String] the `gh api` path
  # @return [Array] the output, the error and whether it succeeded
  def call(path)
    @paths << path
    return [JSON.generate(resources: { core: { remaining: 0, reset: Time.now.to_i + 5 } }), "", true] if path == "rate_limit"
    return ["", "gh: API rate limit exceeded for installation", false] if (@limited -= 1) >= 0

    [JSON.generate(check_runs: runs), "", true]
  end

  private

  def runs
    Hecks::Vocabulary.rows("RequiredCheck").map do |row|
      { name: row["name"], status: "completed", conclusion: "success", id: 1, app: { id: GITHUB_ACTIONS } }
    end
  end
end
