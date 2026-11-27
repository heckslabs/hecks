require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/stuck"
require_relative "support/resident_launch"

# What a spec that leaves a resident too slow to answer waits on before its next line. A loaded
# machine can let a resident given no time answer a line anyway, since the launcher reads a word
# already sent before it waits; that line leaves no `busy` behind, so waiting for a take after it
# would wait for ever.
RSpec.describe ResidentTaken do
  # A spec group's launcher, standing in for `exe/hecks`: each line is answered as the next of
  # `outcomes` says, `:served` (the resident answered, so the launcher forgot any `busy`) or
  # `:busy` (it was too slow, so the launcher noted when it asked), and the resident takes the
  # caller either way.
  let(:group) do
    Class.new do
      include ResidentTaken

      attr_reader :lines

      def initialize(outcomes)
        @outcomes = outcomes
        @lines = 0
      end

      def launch(*)
        @lines += 1
        root = ResidentLaunch::ROOT
        asked = Time.now
        @outcomes.shift == :busy ? stuck.note(root, asked) : stuck.clear(root)
        stuck.took(root)
        ResidentLaunch::Answer.new("", "", 0)
      end

      def stuck = Hecks::Adapters::Driving::Resident::Stuck

      def taken_within = 2
    end
  end

  around do |example|
    saved = ENV.fetch("HECKS_CACHE_DIR", nil)
    Dir.mktmpdir("hrt", ResidentLaunch::SHORT_TMP) do |cache|
      ENV["HECKS_CACHE_DIR"] = cache
      FileUtils.mkdir_p(ResidentLaunch::PATHS.directory)
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end

  it "launches the line again when the resident answered it, until the resident is too slow for one" do
    launcher = group.new(%i[served served busy])
    launcher.launch_until_taken("RedFlag.status")
    expect(launcher.lines).to eq(3)
  end

  it "launches the line once when the resident is too slow for it" do
    launcher = group.new(%i[busy])
    launcher.launch_until_taken("RedFlag.status")
    expect(launcher.lines).to eq(1)
  end
end
