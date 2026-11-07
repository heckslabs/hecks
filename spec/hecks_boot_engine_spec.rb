require "hecks"
require_relative "support/engine_choice"

# `Hecks.boot` left at its default engine follows `HECKS_ENGINE`. The kernel boot is stubbed, so
# no example builds or starts a kernel binary.
RSpec.describe Hecks, ".boot engine choice" do
  include EngineChoice

  let(:pizzas_dir) { File.expand_path("../examples/pizzas", __dir__) }

  before { allow(Hecks::Assembly).to receive(:boot_kernel).and_return(:kernel_dispatcher) }

  it "boots on the kernel when HECKS_ENGINE=kernel" do
    with_engine("kernel")
    expect(described_class.boot(pizzas_dir, install_driving: false)).to eq(:kernel_dispatcher)
  end

  it "boots in process when HECKS_ENGINE=ruby" do
    with_engine("ruby")
    expect(described_class.boot(pizzas_dir, install_driving: false)).to be_a(Hecks::Runtime::Dispatcher)
  end
end
