require "spec_helper"
require "open3"
require "hecks/adapters/driving/resident/foreground"
require_relative "support/resident_launch"

# A resident leaves the background band of macOS whoever started it: a launchd beat puts its
# launcher there, and the resident that launcher starts serves every line of the checkout. The
# launch examples start a real resident from a launcher run under `taskpolicy -b`, and read the
# process table; they run only on macOS, where the band exists.
RSpec.describe Hecks::Adapters::Driving::Resident::Foreground do
  # Whether this machine has the background band and the tool that puts a launcher in it.
  MAC_BAND = RUBY_PLATFORM.include?("darwin") && File.executable?("/usr/sbin/taskpolicy")

  describe "off macOS" do
    it "changes nothing" do
      expect(described_class.apply(platform: "x86_64-linux")).to be(false)
    end

    it "reads no band" do
      expect(described_class.background?(platform: "x86_64-linux")).to be(false)
    end
  end

  describe "a resident whose launcher runs in the background band", if: MAC_BAND do
    include ResidentLaunch

    # Runs a launcher line under `taskpolicy -b`, as a launchd beat with `ProcessType Background`
    # would run it.
    def launch_in_background
      Open3.capture3(env(true), "/usr/sbin/taskpolicy", "-b", File.join(ResidentLaunch::ROOT, "exe/hecks"),
                     "--help", chdir: ResidentLaunch::ROOT)
    end

    # @return [Integer] the scheduling priority the process table shows for the process
    def priority_of(pid) = Integer(Open3.capture2("ps", "-o", "pri=", "-p", pid.to_s).first.strip)

    before do
      stop_resident
      launch_in_background
    end

    after { stop_resident }

    it "runs at the default priority, not the background band's" do
      expect(priority_of(wait_for_resident)).to eq(31)
    end
  end
end
