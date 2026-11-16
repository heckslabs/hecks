# frozen_string_literal: true

require "hecks/hecks/adapters/ci_runs/pull_cache"

# Every example starts with no pull request read held by the process-wide `CiRuns::PullCache`, so
# one example's fake `gh` answer is never read by the next.
RSpec.configure do |config|
  config.before { Hecks::Adapters::CiRuns::PullCache.shared.clear }
end
