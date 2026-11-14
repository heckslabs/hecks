# frozen_string_literal: true

require "spec_helper"

RSpec.describe AmbientRegistryGuard do
  let(:example) { Struct.new(:full_description).new("a leaky example") }
  let(:registry) { Hecks::Runtime::Registry.new }

  it "passes an example that ends with the registry it started with" do
    Hecks.with_registry(registry) do
      expect { described_class.leaked(registry, example) }.not_to raise_error
    end
  end

  it "raises a named violation for an example that left the registry changed" do
    expect { described_class.leaked(registry, example) }
      .to raise_error(described_class::Leaked, /left changed by: a leaky example/)
  end

  it "drops a stand-in that is not a registry, with a warning" do
    expect { described_class.sound(Object.new, example) }
      .to output(/ambient registry was #<Object.* before: a leaky example/).to_stderr
  end

  it "holds the registry per thread, so another thread's binding is not seen" do
    before = Hecks.current_registry
    Thread.new { Hecks.with_registry(registry) { nil } }.join
    expect(Hecks.current_registry).to equal(before)
  end
end
