require "spec_helper"
require "hecks/fuzzing/sequence_generator"

RSpec.describe Hecks::Fuzzing::SequenceGenerator::Drive do
  it "closes the kernel runtime when the generation raises" do
    runtime = instance_double(Hecks::Runtime::KernelDispatcher, close: nil)
    described_class.kernel(runtime) { raise "generation failed" }
  rescue RuntimeError
    expect(runtime).to have_received(:close)
  end

  it "never builds a kernel binary for the Ruby engine" do
    binary = -> { raise "built a kernel" }
    allow(Hecks).to receive(:boot).and_return(:booted)
    expect(described_class.open(:ruby, "copy", "domain", binary: binary) { |runtime| runtime }).to eq(:booted)
  end
end
