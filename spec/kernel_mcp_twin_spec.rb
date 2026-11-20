require "hecks"
require "hecks/rust_build/kernel_engine"
require "hecks/adapters/driving/mcp"
require_relative "support/driving_twin"

# The MCP server's dispatch tool over both engines, on pizzas: an unrestricted server boots the
# domain for each call under `HECKS_ENGINE`, and answers the same on the kernel as in process.
RSpec.describe "the MCP server on the kernel engine", :io do
  include DrivingTwin

  it "dispatches the same through both engines" do
    ruby, kernel = %w[ruby kernel].map { |engine| mcp_create(engine) }
    expect(kernel).to eq(ruby).and(include(ok: true))
  end

  it "gives a refused role the same refusal through both engines" do
    ruby, kernel = %w[ruby kernel].map { |engine| mcp_create(engine, role: "Customer") }
    expect(kernel).to eq(ruby)
  end
end
