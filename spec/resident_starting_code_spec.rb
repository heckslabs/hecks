require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/resident/starting"

# A resident runs the code of the checkout it serves, whichever checkout asks for it to start
# (the delivery worktree warm-up already starts a worktree's resident this way). A resident that
# ran the caller's code would load the served checkout's vendored adapters and the caller's both.
RSpec.describe "the code a resident runs" do
  let(:starting) { Hecks::Adapters::Driving::Resident::Starting }
  let(:script) { File.expand_path("../exe/hecks", __dir__) }
  let(:callers_lib) { File.expand_path("../lib", __dir__) }

  SERVER = "lib/hecks/adapters/driving/resident/server.rb".freeze

  def checkout(dir, resident: true)
    server = File.join(dir, SERVER)
    FileUtils.mkdir_p(File.dirname(server))
    FileUtils.touch(server) if resident
    dir
  end

  it "is the served checkout's own, when it holds a resident" do
    Dir.mktmpdir("hrsc") do |dir|
      command = starting.server_command(checkout(dir), script)
      expect(command.values_at(2, 3)).to eq([File.join(dir, "lib"), File.join(dir, SERVER)])
    end
  end

  it "is the caller's, when the served checkout holds none" do
    Dir.mktmpdir("hrsc") do |dir|
      command = starting.server_command(checkout(dir, resident: false), script)
      expect(command[2]).to eq(callers_lib)
    end
  end

  def stand_in_for_the_process_table
    resident = Hecks::Adapters::Driving::Resident
    allow(Process).to receive_messages(spawn: 1, detach: nil)
    allow(starting).to receive_messages(lock_held?: false)
    allow(resident::Claim).to receive(:take?).and_return(true)
    allow(resident::Crowd).to receive(:crowded?).and_return(false)
  end

  it "is what the spawn is given" do
    Dir.mktmpdir("hrsc") do |dir|
      stand_in_for_the_process_table
      starting.call(checkout(dir), script)
      expect(Process).to have_received(:spawn)
        .with(anything, anything, "-I", File.join(dir, "lib"), anything, dir, anything, anything)
    end
  end
end
