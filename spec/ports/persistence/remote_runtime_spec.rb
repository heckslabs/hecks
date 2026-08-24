require "hecks"
require "hecks/adapters/driven/lambda"
require "hecks/adapters/driven/postgres"

# `Ports::Persistence::RemoteRuntime` — the shared shape for "the real
# interpreter lives behind a call boundary," named so it's a real,
# checkable capability (`registry.adapter_class(name) <= RemoteRuntime`,
# `Runtime::RemoteDispatcher`'s own use) rather than one adapter's own
# ad hoc raise/[] implementation compared by name. Proven against a bare
# double first (the module's own contract shouldn't need a live AWS
# client to prove), then against the two real adapters that answer this
# capability question differently.
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
    expect(Hecks::Adapters::Lambda <= described_class).to be(true)
  end

  it "a local adapter (Postgres) does not include it" do
    expect(Hecks::Adapters::Postgres <= described_class).to be_falsy
  end
end
