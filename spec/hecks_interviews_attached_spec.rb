require "hecks"

# Interviews is a task module of the one Hecks context (ADR 0194, decision 6), kept in Memory by
# the committed world (decision 7): a SQLite hecksagon is for a local overlay only.
RSpec.describe "the Hecks domain attaching Interviews" do
  let(:directory) { File.expand_path("../lib/hecks/hecks", __dir__) }
  let(:registry) { Hecks.describe(directory).registry.tap(&:apply_world_names!) }

  it "carries the Interviews bluebook with its Interview aggregate" do
    expect(registry.bluebook("Interviews").aggregate("Interview")).not_to be_nil
  end

  it "lists Interview.record! among the commands of the Hecks context" do
    expect(registry.bluebook("Interviews").aggregate("Interview").commands.map(&:hecks_name)).to include("Record")
  end

  it "names no SQLite for Interviews in the committed world" do
    committed = Dir.glob([File.join(directory, "*.{hecksagon,world}"), File.join(directory, "../interviews/*.hecksagon")])
    named = committed.reject { |path| path.include?(".local.") }.flat_map { |path| File.readlines(path) }
    expect(named.grep(/sqlite/i).grep(/interview/i)).to be_empty
  end
end
