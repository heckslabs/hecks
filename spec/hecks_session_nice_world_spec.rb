require "spec_helper"
require "hecks/rust_build/world_rows"

# The committed Tickets world declares how nicely a coder's session runs. A session niced to 15
# or more is capped at the bottom of the scheduler and starves behind the beat and the board.
# The owner's local worlds replace the line when present, so the committed file is read as text.
RSpec.describe "the session nice the Tickets world declares" do
  let(:world) { File.read(File.join(Hecks::RustBuild::ROOT, Hecks::RustBuild::WorldRows::WORLD)) }
  let(:declared) { world[/^\s*session_environment .*nice:\s*(\d+)/, 1].to_i }

  it "keeps every session below nice 15" do
    expect(declared).to be_between(1, 14)
  end
end
