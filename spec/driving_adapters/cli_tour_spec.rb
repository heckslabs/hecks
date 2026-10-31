require "spec_helper"
require "tmpdir"

# `hecks tour [dir]` (ADR 0163, plan step 40) writes a sample domain into a directory that does not
# exist yet, runs its one command, and says what to type next. A directory that exists is refused.
RSpec.describe Hecks::Adapters::Driving::CliRunner::TourWords do
  let(:host) { Object.new.extend(described_class) }
  let(:scope) { { program: "hecks" } }
  let(:exit_status) { Hecks::Adapters::Driving::ExitStatus }

  def tour(dir) = host.tour_answer(scope, ["tour", dir])
  def lines(answer) = Array(answer).join("\n")

  it "writes the sample bluebook" do
    Dir.mktmpdir do |root|
      tour(File.join(root, "demo"))
      expect(File.exist?(File.join(root, "demo", "bluebook", "tour.bluebook"))).to be(true)
    end
  end

  it "prints the result of the command and exits 0" do
    Dir.mktmpdir do |root|
      answer, status = tour(File.join(root, "demo"))[:answer]
      expect([lines(answer).include?("ExampleCreated"), status]).to eq([true, exit_status::ANSWERED])
    end
  end

  it "refuses a directory that already exists, with exit status 1" do
    Dir.mktmpdir do |root|
      _, status = tour(root)[:answer]
      expect(status).to eq(exit_status::REFUSED)
    end
  end

  it "names the next command to type" do
    Dir.mktmpdir do |root|
      answer, = tour(File.join(root, "demo"))[:answer]
      expect(lines(answer)).to include("next: hecks run")
    end
  end
end
