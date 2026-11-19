# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# `policy_only` on a command and `acts_as` on a policy (ADR 0216): the bluebook words that say how
# a caller who states no role is treated, carried on the IR by both parsers alike.
RSpec.describe "policy_only and acts_as", :io do
  PLANT = <<~RUBY
    Hecks.bluebook "Plant" do
      vision "A plant waters itself when it wilts."

      aggregate "Plant" do
        identified_by :tag
        attribute :tag, Tag

        value_object "Tag" do
          attribute :value, String
        end

        command "Wilt" do
          role "Gardener"
          sets :tag
          emits "PlantWilted"
        end

        command "Water" do
          role "System"
          policy_only
          reference_to Plant
          emits "PlantWatered"
        end
      end

      policy "WaterWhenWilted" do
        on "PlantWilted"
        acts_as "System"
        trigger Plant::Water, with: { plant: :tag }
      end
    end
  RUBY

  let(:binary) { File.expand_path("../rust/parser/target/debug/hecks-parse", __dir__) }
  let(:scratch) { Dir.mktmpdir }
  let(:path) { File.join(scratch, "plant.bluebook").tap { |file| File.write(file, PLANT) } }

  # The binary comes from the Build command's parser ask, not a hand build.
  before { Hecks::Adapters::RustToolchain.new.parser unless File.exist?(binary) }

  after { FileUtils.remove_entry(scratch) }

  # The IR Ruby exports for the fixture, as the hash the exporter builds.
  def ruby_ir
    registry = Hecks::Runtime::Registry.new(root: scratch)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(path)
    end
    JSON.parse(JSON.generate(Hecks::Projector::Exporter.call(registry).fetch("Plant")))
  end

  # The same file read by the Rust parser.
  def rust_read = Open3.capture3(binary, "bluebook", "--bluebook", "Plant", path)

  # One command of the fixture's IR, by name.
  def command_ir(name) = ruby_ir.fetch("aggregates").first.fetch("commands").find { |c| c["name"] == name }

  it "carries policy_only on the command that says it" do
    expect(command_ir("Water")).to include("policy_only" => true)
  end

  it "carries no policy_only key on a command that does not say it" do
    expect(command_ir("Wilt")).not_to have_key("policy_only")
  end

  it "carries the role a policy acts as" do
    expect(ruby_ir.fetch("policies").first).to include("acts_as" => "System")
  end

  it "reads both words in Rust, byte for byte with the IR Ruby exports", :aggregate_failures do
    out, err, = rust_read
    expect(err).to be_empty
    expect(out).to eq("#{JSON.pretty_generate(ruby_ir)}\n")
  end

  it "refuses an acts_as that names no role" do
    build = -> { Hecks::Bluebook::DSL::PolicyBuilder.build("Blank") { acts_as "" } }
    expect(&build).to raise_error(Hecks::Bluebook::DSL::Malformed, /acts_as with no role/)
  end
end
