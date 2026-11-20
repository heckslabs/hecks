require "hecks"
require "hecks/rust_build/kernel_client"
require "hecks/runtime/kernel_dispatcher"
require "hecks/adapters/driving/mcp"

# An unrestricted MCP server boots its domain for each call; on the kernel engine the kernel it
# booted is closed when the call ends, whether the call answered or raised. No kernel is built:
# the boot answers a kernel dispatcher over a stand-in client.
RSpec.describe Hecks::Adapters::Driving::Mcp::CallBoots do
  let(:client) { instance_double(Hecks::RustBuild::KernelClient, close: nil) }
  let(:calls) { Object.new.extend(described_class) }

  before { allow(Hecks).to receive(:boot).and_return(Hecks::Runtime::KernelDispatcher.new(client)) }

  it "closes the kernel a call booted when the call answers" do
    calls.closing_call_boots { calls.call_boot("pizzas") }
    expect(client).to have_received(:close)
  end

  it "closes the kernel a call booted when the call raises", :aggregate_failures do
    expect { calls.closing_call_boots { calls.call_boot("pizzas") && raise("broken") } }.to raise_error("broken")
    expect(client).to have_received(:close)
  end

  it "leaves a Ruby engine boot alone" do
    allow(Hecks).to receive(:boot).and_return(:ruby_dispatcher)
    expect(calls.closing_call_boots { calls.call_boot("pizzas") }).to eq(:ruby_dispatcher)
  end
end
