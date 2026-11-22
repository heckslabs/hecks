# frozen_string_literal: true

require "spec_helper"

# A spec run never lists sessions through the real `claude`, which opens the desktop app.
RSpec.describe LiveSessionGuard do
  it "refuses a real session listing by name" do
    expect(described_class.refusal(%w[claude agents --json --all], {})).to match(/real claude session/)
  end

  it "lets a command for another program run" do
    expect(described_class.refusal(%w[git status], {})).to be_nil
  end
end
