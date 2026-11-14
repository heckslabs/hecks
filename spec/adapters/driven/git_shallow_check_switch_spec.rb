# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"
require_relative "../../support/shallow_repo"

# The switch works both ways, and Landing.finish! refuses at the check.
RSpec.describe Hecks::Adapters::GitShallowCheck, "#shallow_switch" do
  include ShallowRepo

  it "does nothing when switched off, and checks again when switched on", :aggregate_failures do
    build_repo("lib/a.rb")
    switch("off")
    expect(shallow[:report][:value]).to eq("shallow check is off")
    switch("on")
    expect { shallow }.to raise_error(failure, /shallow check red/)
  end

  it "refuses a switch that is neither on nor off" do
    build_repo("lib/a.rb")
    expect { switch("maybe") }.to raise_error(failure, /on or off/)
  end

  it "makes Landing.finish! refuse at the shallow check, leaving the branch unlanded", :aggregate_failures do
    build_repo("lib/a.rb")
    expect { finish }.to raise_error(failure, %r{shallow check red: spec/depth_spec\.rb})
    expect(git("branch", "--list", "work/a")).to include("work/a")
  end
end
