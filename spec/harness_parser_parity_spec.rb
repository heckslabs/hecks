require "spec_helper"
require "json"
require "open3"
require_relative "support/hecks_parse_binary"

# The Harness bluebook reads the same through the Rust parser as through Ruby: `hecks-parse`'s
# ir.json for harness.bluebook and its hecksagon is byte-identical to the Ruby exporter's, as
# spec/parser_parity_spec.rb holds each example domain to.
RSpec.describe "the Harness bluebook through the Rust parser", :io do
  include_context "with the hecks-parse binary"

  let(:paths) { %w[harness.bluebook harness.hecksagon].map { |file| File.join(InMemoryDomain::ROOT, "lib/hecks/harness", file) } }

  def ruby_ir(paths)
    registry = Hecks::Runtime::Registry.new(root: File.dirname(paths.first, 2))
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      InMemoryDomain.load_bluebook_files([paths.first])
      Kernel.load(paths.last)
    end
    "#{JSON.pretty_generate(Hecks::Projector::Exporter.call(registry).fetch("Harness"))}\n"
  end

  it "projects the IR Ruby projects, byte for byte" do
    rust, = Open3.capture3(HecksParseBinary.build!, "bluebook", "--bluebook", "Harness", *paths)
    expect(rust).to eq(ruby_ir(paths))
  end
end
