require "hecks"
require_relative "support/engine_choice"

# Which engine a boot runs a domain on: the caller's `engine:`, else `HECKS_ENGINE`, else `:ruby`.
# No example builds or starts a kernel binary.
RSpec.describe Hecks::Assembly, ".selected_engine" do
  include EngineChoice

  { nil => :ruby, " " => :ruby, "ruby" => :ruby, "kernel" => :kernel }.each do |value, engine|
    it "reads HECKS_ENGINE=#{value.inspect} as #{engine.inspect}" do
      with_engine(value)
      expect(default_engine).to eq(engine)
    end
  end

  it "lets an explicit engine: :ruby win over HECKS_ENGINE=kernel" do
    with_engine("kernel")
    expect(described_class.selected_engine(:ruby)).to eq(:ruby)
  end

  it "refuses an unknown HECKS_ENGINE by name, never falling back" do
    with_engine("wasm")
    expect { default_engine }.to raise_error(ArgumentError, /unknown engine :wasm — one of :ruby, :kernel/)
  end
end
