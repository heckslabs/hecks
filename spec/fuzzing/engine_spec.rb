require "spec_helper"
require "hecks/fuzzing"

RSpec.describe Hecks::Fuzzing::Engine do
  let(:pizzas) { File.join(InMemoryDomain::ROOT, "spec/fixtures/pizza_fixture") }
  let(:steps) do
    [{ "verb" => "PizzaFixture::Order.CreatePizza",
       "args" => { "name"  => { "value" => "Margherita" },
                   "pizza" => { "price_cents" => { "cents" => 1200 }, "size" => { "value" => "large" } } } }]
  end

  def fake_kernel(dir, script)
    File.join(dir, "kernel").tap { |path| File.write(path, "#!/bin/sh\ncat >/dev/null\n#{script}\n", perm: 0o755) }
  end

  it "replays on the Ruby engine exactly as Replay.call does" do
    history = described_class::Ruby.new.call(pizzas, steps)
    expect(history.except(:bluebook, :bluebooks)).to eq(Hecks::Fuzzing::Replay.call(pizzas, steps).except(:bluebook, :bluebooks))
  end

  it "answers the kernel binary's run output, parsed" do
    Dir.mktmpdir do |dir|
      kernel = described_class::Kernel.new(fake_kernel(dir, %(echo '{"instances": {}}')))
      expect(kernel.call(pizzas, steps)).to eq("instances" => {})
    end
  end

  it "refuses by name when the kernel binary exits unsuccessfully" do
    Dir.mktmpdir do |dir|
      kernel = described_class::Kernel.new(fake_kernel(dir, "echo broken; exit 3"))
      expect { kernel.call(pizzas, steps) }.to raise_error(described_class::Kernel::Failed, /exited 3: broken/)
    end
  end
end
