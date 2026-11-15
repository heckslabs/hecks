# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/quieting"

# A landing runs on after the session that asked for it is gone, under a wrapper whose parent is
# launchd, and its gate starts spec runs that carry no worktree name. The landings are found by what
# they are called, and what they started by who their parent is.
RSpec.describe Hecks::Adapters::Quieting::LandingTrees do
  let(:rows) do
    [[1, 0, "/sbin/launchd"],
     [100, 1, "ruby -e log = ARGV.pop;launcher, flag, t"],
     [101, 100, "ruby --disable-gems exe/hecks Landing.carry! checkout.value=/x"],
     [102, 101, "ruby --disable-gems exe/hecks test_suite_run.run_spec_example! file.value=spec/a_spec.rb"],
     [200, 1, "hecks resident hecks (resident/server.rb /x)"],
     [201, 200, "exe/hecks Landing.finish!"],
     [300, 1, "ruby exe/hecks send_train.board! --confirm"],
     [301, 300, "ruby exe/hecks regeneration_run.regenerate_corpus! --check"]]
  end
  let(:table) { -> { rows.map { |pid, ppid, command| "#{pid} #{ppid} #{command}" }.join("\n") } }
  let(:killed) { [] }
  let(:trees) { described_class.new(table: table, kill: ->(pid) { killed << pid }, rounds: 1, pause: 0, own: [9999]) }

  it "finds each landing and everything it started, by ancestry", :aggregate_failures do
    expect(trees.victims(rows)).to contain_exactly(100, 101, 102, 201)
    expect(trees.victims(rows)).not_to include(200)
  end

  it "never ends a boarding, whose checks are the point of the window" do
    expect(trees.victims(rows)).not_to include(300, 301)
  end

  it "never ends the process asking, nor the ones above it, but ends a landing beside them", :aggregate_failures do
    own = described_class.new(table: table, kill: ->(_pid) {}, rounds: 1, pause: 0, own: [101])

    expect(own.victims(rows)).to eq([201])
  end

  it "ends what it found and answers the processes ended", :aggregate_failures do
    expect(trees.end_all).to contain_exactly(100, 101, 102, 201)
    expect(killed).to contain_exactly(100, 101, 102, 201)
  end
end
