# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "a sum over a list, read by hecks-parse", :io do
  CART_WITH_SUM = <<~RUBY
    Hecks.bluebook "Cart" do
      vision "A cart holds priced lines."

      aggregate "Cart" do
        description "A cart a customer fills."
        identified_by :number

        attribute :number, CartNumber
        attribute :lines, list_of(Line)

        value_object "CartNumber" do
          attribute :value, String
        end

        value_object "Line" do
          attribute :price, Integer
          attribute :quantity, Integer
        end

        command "Open" do
          attribute :number, CartNumber
          given("the lines stay within the limit") { lines.sum { |l| l.quantity * l.price } <= 1000 }
        end
      end
    end
  RUBY

  let(:binary) { File.expand_path("../rust/parser/target/debug/hecks-parse", __dir__) }
  let(:scratch) { Dir.mktmpdir }
  let(:path) { File.join(scratch, "cart.bluebook").tap { |file| File.write(file, CART_WITH_SUM) } }
  let(:read) { Open3.capture3(binary, "bluebook", "--bluebook", "Cart", path) }

  # The binary comes from the Build command's parser ask, not a hand build, so a missing one is built
  # here and a failed build fails the example.
  before { Hecks::Adapters::RustToolchain.new.parser unless File.exist?(binary) }

  after { FileUtils.remove_entry(scratch) }

  # The IR Ruby exports for the same file.
  def ruby_ir
    registry = Hecks::Runtime::Registry.new(root: scratch)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(path)
    end
    "#{JSON.pretty_generate(Hecks::Projector::Exporter.call(registry).fetch("Cart"))}\n"
  end

  it "reads it without complaint" do
    expect(read[1]).to be_empty
  end

  it "spells the sum in the IR" do
    expect(read[0]).to include('"op": "sum"')
  end

  it "gives the IR Ruby exports, byte for byte" do
    expect(read[0]).to eq(ruby_ir)
  end
end
