# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/git_shallow_check"
require_relative "../../support/shallow_repo"

# CI's failing checks run at landing in a depth-1 clone of the branch tip.
RSpec.describe Hecks::Adapters::GitShallowCheck, "#shallow_check" do
  include ShallowRepo

  it "passes on a full checkout, so only the shallow clone can fail", :aggregate_failures do
    build_repo("lib/a.rb")
    out, status = Open3.capture2e(RbConfig.ruby, "-S", "rspec", "--no-color", "spec/depth_spec.rb", chdir: tree)
    expect(status).to be_success, out
    expect(git("rev-list", "--count", "HEAD", chdir: tree).to_i).to be > 1
  end

  it "refuses a landing a depth-1 clone fails, naming the spec and the first failure line" do
    build_repo("lib/a.rb")
    expect { shallow }.to raise_error(failure, %r{shallow check red: spec/depth_spec\.rb: Failure/Error: .* depth-1 clone})
  end

  it "passes a hecksagon change when the clone is green" do
    build_repo("lib/a.hecksagon")
    expect(shallow(specs: [], command: ["true"])[:report][:value]).to include("green")
  end

  it "does not clone for a docs-only landing" do
    build_repo("docs/guide.md")
    expect(shallow(command: ["false"])[:report][:value]).to include("skipped")
  end
end
