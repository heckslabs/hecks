require "spec_helper"

# The driving adapter names are declared in the Hecksagon bluebook and copied by Ruby and by the
# Rust parser. This holds the three copies equal, so a name added in one place cannot be refused in
# another.
RSpec.describe "The driving adapter names" do
  def read(path) = File.read(File.expand_path("../../#{path}", __dir__))

  let(:declaration) { /value_object "DrivingAdapter" do\s+attribute :value, String, one_of: %w\[([^\]]+)\]/ }

  let(:declared) { read("lib/hecks/language/hecksagon/hecksagon.bluebook")[declaration, 1].split }

  it "declares the names the Ruby builder admits" do
    expect(declared).to eq(Hecks::Bluebook::Hecksagon::DRIVING_ADAPTERS)
  end

  it "declares the names the Rust parser admits" do
    rust = read("rust/parser/src/parse/hecksagon.rs")[/DRIVING_ADAPTERS: \[&str; \d+\] = \[([^\]]+)\]/, 1].scan(/"(\w+)"/).flatten

    expect(declared).to eq(rust)
  end
end
