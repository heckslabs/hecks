require "spec_helper"
require "json"
require "open3"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# `hecks-parse adapter <file>` must print what the Ruby exporter makes of the same `.adapter`
# file, byte for byte. The invariant examples need no binary; the comparison builds it.
RSpec.describe "Rust adapter parity (hecks-parse adapter)" do
  ADAPTER_PARITY_FILES = Hecks::Corpus.adapter_files.freeze
  ADAPTER_PARITY_KEYS  = %w[name port fields secrets defaults].freeze
  # A plugin adapter (`answers_query`, `runs`) adds the queries it answers and its module file.
  PLUGIN_PARITY_KEYS   = (ADAPTER_PARITY_KEYS + %w[answers runs]).freeze

  def exported(path) = Hecks::Projector::Exporter.adapters_in_files([path])

  def exported_json(path) = Hecks::Projector::Exporter.adapters_json([path])

  def native_value?(value) = [true, false, nil].include?(value) || value.is_a?(String) || value.is_a?(Integer)

  def string_lists?(adapter) = (adapter["fields"] + adapter["secrets"] + adapter.fetch("answers", [])).all?(String)

  def contract_shape(adapter)
    lists = string_lists?(adapter)
    [adapter.keys, adapter["name"].is_a?(String), adapter["port"].nil? || adapter["port"].is_a?(String), lists,
     adapter["defaults"].values.all? { |value| native_value?(value) }]
  end

  it "finds every .adapter file, none in a vendored or build directory", :aggregate_failures do
    expect(ADAPTER_PARITY_FILES).not_to be_empty
    expect(ADAPTER_PARITY_FILES.grep(%r{/(vendor|node_modules|target)/})).to be_empty
  end

  it "exports every real adapter file in the contract's keys, order and types" do
    shapes = ADAPTER_PARITY_FILES.flat_map { |path| exported(path).map { |adapter| contract_shape(adapter) } }
    expect(shapes.uniq - [[PLUGIN_PARITY_KEYS, true, true, true, true]]).to eq([[ADAPTER_PARITY_KEYS, true, true, true, true]])
  end

  it "exports heki as the contract's example" do
    path = ADAPTER_PARITY_FILES.find { |file| file.end_with?("/heki.adapter") }
    expect(exported(path)).to eq([{ "name" => "Heki", "port" => "persistence", "fields" => ["dir"],
                                    "secrets" => [], "defaults" => { "dir" => "data" } }])
  end

  context "with the Rust parser", :io do
    include_context "with the hecks-parse binary"

    def printed(path)
      stdout, status = Open3.capture2(Hecks::Composer::Parse.binary, "adapter", path)
      raise "hecks-parse adapter #{path} exited #{status.exitstatus}" unless status.success?

      stdout.chomp
    end

    ADAPTER_PARITY_FILES.each do |path|
      it "prints #{path.delete_prefix("#{Hecks::Corpus::ROOT}/")} as Ruby exports it" do
        expect(printed(path)).to eq(exported_json(path))
      end
    end
  end
end
