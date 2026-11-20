require "hecks"
require_relative "support/kernel_twin"
require_relative "support/behaviors_on_kernel"

# Every `.behaviors` file whose domain has a kernel feature in `rust/Cargo.toml`, run on the Rust
# kernel and on the in-process engine: each test ends the same way on both, or it is named in
# `spec/behaviors/kernel_differences.yml` with the reason. A listed test whose outcomes now agree
# fails here, so the list only shrinks. A suite whose domain has no feature waits, counted in the
# group's description, and is run by the in-process leg alone.
RSpec.describe "behaviors on the kernel (#{BehaviorsOnKernel.waiting.size} suites wait for a kernel feature)", :io do
  include KernelTwin

  BehaviorsOnKernel.cases.each do |kase|
    it kase.title do
      expect(BehaviorsOnKernel.mismatch(kase)).to be_nil
    end
  end

  it "lists only tests that exist" do
    expect(BehaviorsOnKernel.unknown_differences).to be_empty
  end
end
