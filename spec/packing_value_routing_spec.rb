require "spec_helper"

# A command value routed to the port operation its hecksagon names (ADR 0163 step 52).
RSpec.describe "a command value, routed to the operation that handles it" do
  BUILDERS = proc do
    operation "BuildWasm" do
      attribute :target, Target
      emits "PackBuilt"
      handles "Pack.build!", value: "wasm"
    end

    operation "BuildHost" do
      attribute :target, Target
      emits "PackBuilt"
      handles "Pack.build!", value: "host"
    end

    operation "BuildBrowser" do
      attribute :target, Target
      emits "PackBuilt"
      handles "Pack.build!", value: "browser"
    end
  end

  def boot
    @registry = Hecks::Runtime::Registry.new
    declare_bluebook
    declare_hecksagon
    @registry.verify!
    Hecks::Runtime::Dispatcher.new(@registry)
  end

  def declare_bluebook
    Hecks.with_registry(@registry) do
      MemoryPorts.load!
      Kernel.load(File.join(InMemoryDomain::ROOT, "spec/fixtures/packing.bluebook"))
    end
  end

  def declare_hecksagon
    Hecks.with_registry(@registry) do
      Hecks.hecksagon("Packing") do
        Packing::Pack.persisted_by("Memory")
        Packing::Pack.port("Builder", &BUILDERS)
      end
    end
  end

  def ran_operations(dispatcher)
    interpreter = dispatcher.instance_variable_get(:@port_ops)
    calls = []
    allow(interpreter).to receive(:call).and_wrap_original do |original, *args|
      calls << args[2].hecks_name
      original.call(*args)
    end
    calls
  end

  def open_pack(dispatcher) = dispatcher.dispatch_flat("Packing::Pack.Open", pack_id: { value: "P1" })

  def build(dispatcher, target) = dispatcher.dispatch_flat("Packing::Pack.Build", to: "P1", target: { value: target })

  it "routes each handled value to its own operation" do
    dispatcher = boot
    open_pack(dispatcher)
    calls = ran_operations(dispatcher)
    %w[wasm host browser].each { |value| build(dispatcher, value) }
    expect(calls).to eq(%w[BuildWasm BuildHost BuildBrowser])
  end

  it "refuses a value no operation handles, naming the handled values" do
    dispatcher = boot
    open_pack(dispatcher)
    expect { build(dispatcher, "other") }.to raise_error(Hecks::Runtime::UnknownVerb, /handles "wasm, host, browser"/)
  end
end
