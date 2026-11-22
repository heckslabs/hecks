# frozen_string_literal: true

require "spec_helper"
require_relative "support/gate_passed_on_context"

# A gate check that already passed on the same file contents and the same tools is skipped; a
# check that read a changed file, or ran under other tools, runs again.
RSpec.describe "Hecks::Tools::GateMemo reuse" do
  include_context "a checkout with a gate memo"

  it "runs nothing on a repeated run over unchanged files" do
    pass([shape, fmt])
    expect(pass([shape, fmt]).run).to be_empty
  end

  it "reruns only the check that reads a changed file" do
    pass([shape, fmt])
    write("lib/a.rb", "A = 2\n")
    expect(pass([shape, fmt]).run.map { |c| c["id"] }).to eq(["shape_ledger"])
  end

  it "reruns a check when the ruby version changed" do
    pass([shape])
    stub_const("RUBY_VERSION", "0.0.0")
    expect(session.plan([shape]).run).to eq([shape])
  end

  it "reruns a check when the bundle's lock changed" do
    pass([shape])
    write("Gemfile.lock", "lock 2\n")
    expect(session.plan([shape]).run).to eq([shape])
  end
end
