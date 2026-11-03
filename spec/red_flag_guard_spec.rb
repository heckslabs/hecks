require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/red_flag_marker"
require "hecks/hecks/adapters/red_flag_guard"

# What a standing red flag refuses: any landing but a red row's fix, and any boarding but that
# fix's tip.
RSpec.describe Hecks::Adapters::RedFlagGuard do
  let(:dir) { Dir.mktmpdir("hecks-red-flag-guard") }
  let(:marker) { Hecks::Adapters::RedFlagMarker.new(dir) }
  let(:guard) { described_class.new(dir) }

  after { FileUtils.remove_entry(dir) }

  def flagged = marker.raise!(commit: "aaaaaaaaaaaa", run: {})

  def refused = raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main is red: flag flag-aaaaaaaaaa/)

  it "lets any branch land while main is not flagged" do
    expect { guard.landing!("feature-x") }.not_to raise_error
  end

  it "refuses a branch that is not a red row's fix, naming the flag" do
    flagged

    expect { guard.landing!("feature-x") }.to refused
  end

  it "lets the fix of a red row land", :aggregate_failures do
    flagged

    expect { guard.landing!("red-flag-stops-work") }.not_to raise_error
    expect { guard.landing!("qa/red-ci-fuzz") }.not_to raise_error
  end

  it "refuses to board a commit that is not the fix's tip" do
    flagged

    expect { guard.boarding!("cccccccccccc") }.to refused
  end

  it "boards the tip a red row's fix landed at" do
    flagged
    guard.landed("red-a", "cccccccccccc")

    expect { guard.boarding!("cccccccccccc") }.not_to raise_error
  end

  it "ignores a landing that is not a fix", :aggregate_failures do
    flagged
    guard.landed("feature-x", "cccccccccccc")

    expect(marker.read).not_to have_key("fix_tip")
  end

  it "boards anything once the flag is down", :aggregate_failures do
    flagged
    marker.clear!

    expect { guard.boarding!("dddddddddddd") }.not_to raise_error
    expect { guard.landing!("feature-x") }.not_to raise_error
  end
end
