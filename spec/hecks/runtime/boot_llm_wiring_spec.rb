# spec/hecks/runtime/boot_llm_wiring_spec.rb
#
# Contract for Hecks::Boot#wire_llm_adapters. Mirrors the unwritten
# wire_shell_adapters contract — verifies that LLM adapters declared
# on a runtime's hecksagon are forwarded to register_llm_adapter so
# `runtime.llm(:name, **attrs)` resolves after boot.
#
# Drives the private wire_llm_adapters method directly via `send` —
# acceptable here because the full boot path requires hecks/ files
# on disk and the contract under test is purely the registration
# fan-out.
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe "Hecks::Boot#wire_llm_adapters" do
  let(:booter) do
    obj = Object.new
    obj.extend(Hecks::Boot)
    obj
  end

  let(:adapter_a) do
    Hecksagon::Structure::LlmAdapter.new(
      name: :greet,
      prompt_template: "Hi {{name}}",
      model: "claude-sonnet-4",
      max_tokens: 50,
      backend: :fixture
    )
  end

  let(:adapter_b) do
    Hecksagon::Structure::LlmAdapter.new(
      name: :dream_image,
      prompt_template: "Imagine {{seed_image}}",
      model: "claude-sonnet-4",
      max_tokens: 100,
      backend: :fixture
    )
  end

  def build_hecksagon(adapters)
    h = Object.new
    h.define_singleton_method(:llm_adapters) { adapters }
    h
  end

  let(:hecksagon_no_method) { Object.new }

  let(:fake_runtime) do
    rt = Object.new
    rt.instance_variable_set(:@registered, [])
    rt.define_singleton_method(:register_llm_adapter) do |a|
      instance_variable_get(:@registered) << a
    end
    rt.define_singleton_method(:registered) { instance_variable_get(:@registered) }
    rt
  end

  it "registers every llm adapter from each runtime's hecksagon" do
    fake_runtime.instance_variable_set(:@hecksagon, build_hecksagon([adapter_a, adapter_b]))
    booter.send(:wire_llm_adapters, [fake_runtime])
    expect(fake_runtime.registered.map(&:name)).to eq(%i[greet dream_image])
  end

  it "skips runtimes whose hecksagon does not respond to :llm_adapters" do
    fake_runtime.instance_variable_set(:@hecksagon, hecksagon_no_method)
    expect { booter.send(:wire_llm_adapters, [fake_runtime]) }.not_to raise_error
    expect(fake_runtime.registered).to be_empty
  end

  it "is a no-op for an empty list of runtimes" do
    expect { booter.send(:wire_llm_adapters, []) }.not_to raise_error
  end
end
