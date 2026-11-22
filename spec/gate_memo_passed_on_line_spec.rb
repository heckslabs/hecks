# frozen_string_literal: true

require "spec_helper"
require_relative "support/gate_passed_on_context"

# The line a skipped check prints names the commit it passed on, only when the tree was clean.
RSpec.describe "Hecks::Tools::GateMemo skip line" do
  include_context "a checkout with a gate memo"

  it "names the commit a check passed on when the tree was clean" do
    sha = commit_all
    pass([shape])
    expect(report_of(session.plan([shape]))).to include("passed on #{sha}")
  end

  it "names no commit when the check passed on uncommitted edits" do
    commit_all
    write("lib/a.rb", "A = 3\n")
    pass([shape])
    expect(report_of(session.plan([shape]))).not_to include("passed on")
  end
end
