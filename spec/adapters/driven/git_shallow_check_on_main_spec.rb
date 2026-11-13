# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"
require_relative "../../support/shallow_repo"

# A red shallow check is compared with a depth-1 clone of the branch it lands on, and the check
# set itself runs in a clone that holds one commit.
RSpec.describe Hecks::Adapters::GitShallowCheck::OnMain do
  include ShallowRepo

  def check_set = Hecks::Adapters::GitShallowCheck::CloneRun::SPECS

  it "says in the refusal that the same spec is green on main" do
    build_repo("lib/a.rb")
    expect { shallow }.to raise_error(failure, /green in a depth-1 clone of main, so the branch's change causes it/)
  end

  it "passes a branch whose only red spec is red on main too, and names it", :aggregate_failures do
    build_repo("lib/a.rb", main_holds: "lib/z.rb")
    report = shallow[:report][:value]
    expect(report).to start_with("shallow check passed: spec/depth_spec.rb: expected: > 1")
    expect(report).to include("red in a depth-1 clone of main too, so the branch does not cause it")
  end

  it "hands the whole check set to the runner in a clone that holds one commit" do
    build_repo("lib/a.rb")
    seen = File.join(dir, "seen")
    Hecks::Adapters::GitShallowCheck.new(command: recorder(seen)).shallow_check(checkout: tree, branch: "work/a", onto: "main")
    expect(File.read(seen).lines.map(&:strip)).to eq(["1", *check_set])
  end

  it "names only spec files this repository holds in the check set" do
    root = File.expand_path("../../..", __dir__)
    expect(check_set.reject { |spec| File.exist?(File.join(root, spec)) }).to be_empty
  end
end
