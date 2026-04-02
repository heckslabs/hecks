require "spec_helper"
require_relative "../lib/hecks_ai/governance_tools"

RSpec.describe Hecks::MCP::GovernanceTools do
  describe ".register" do
    it "responds to register with server and ctx" do
      expect(described_class).to respond_to(:register)
    end
  end
end
