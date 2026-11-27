require "spec_helper"
require_relative "support/shared_file_looks"

# A stall's brief names the command that reads its own row, so its watcher never guesses a key.
RSpec.describe "StallWatch impediments name the row to read" do
  include_context "with open branches that share a file"

  it "tells the watcher the command that reads its own row" do
    write_sources(started)
    expect(pair[:detail]).to include("StallWatch.impediments run=<your run key> stall=#{pair[:stall]}")
  end
end
