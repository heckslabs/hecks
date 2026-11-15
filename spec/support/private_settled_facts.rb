# frozen_string_literal: true

require "tmpdir"

# A spec whose pull request has the same commit and checks in every example keeps what the beat
# reads of it (`CiRuns::SettledFacts`) in a directory of its own, so one example's read is never
# the next one's.
RSpec.shared_context "with private settled facts" do
  around do |example|
    Dir.mktmpdir("settled-facts") do |dir|
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = dir
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end
end
