require "spec_helper"
require_relative "support/disk_space_rows"

# The caches the DiskSpace bluebook can clear, and what clearing one asks for.
RSpec.describe "the DiskSpace caches", :aggregate_failures do
  include DiskSpaceRows

  it "carries the cold-cache cost on every cache kind" do
    expect(rows("Cache", "CacheKind").map { |row| row[:rebuild_cost] }).to all(satisfy { |cost| !cost.empty? })
  end

  it "asks for --confirm to clear a cache, and takes no caller-supplied holder state" do
    expect(givens("Cache", "Clear")).to match([/needs --confirm/])
  end
end
