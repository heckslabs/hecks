require "hecks"
require "hecks/adapters/driven/lambda"
require "hecks/adapters/driven/postgres"

# `RemoteRuntime` is proven against a bare double, then against the two real adapters
# that answer the remote-runtime question differently.
RSpec.describe Hecks::Ports::Persistence::RemoteRuntime do
  let(:delegate_class) { Class.new { include Hecks::Ports::Persistence::RemoteRuntime } }

  it "entries is always empty — there is no local write-ahead log to replay" do
    expect(delegate_class.new.entries).to eq([])
  end

  it "append raises rather than silently no-opping" do
    expect { delegate_class.new.append(:whatever) }
      .to raise_error(Hecks::Runtime::WiringError, /remote-runtime delegate/)
  end

  it "project raises the same way append does — same delegate, same reason" do
    expect { delegate_class.new.project(:whatever) }
      .to raise_error(Hecks::Runtime::WiringError, /remote-runtime delegate/)
  end

  it "Adapters::Lambda includes it — a real capability, not a name comparison" do
    expect(described_class >= Hecks::Adapters::Lambda).to be(true)
  end

  it "a local adapter (Postgres) does not include it" do
    expect(described_class >= Hecks::Adapters::Postgres).to be_falsy
  end
end
