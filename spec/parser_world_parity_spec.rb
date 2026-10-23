require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# `hecks-parse world <file>...` must print what the Ruby exporter makes of the same `.world`
# files, byte for byte. The contract examples need no binary; the comparison builds it.
RSpec.describe "Rust world parity (hecks-parse world)" do
  WORLD_PARITY_FILES = Hecks::Corpus.world_files.freeze
  WORLD_PARITY_KEYS  = %w[domain realm latest default_adapter default_database bindings].freeze
  BINDING_KEYS       = %w[verb adapter settings].freeze

  def exported(paths) = Hecks::Projector::Exporter.worlds_in_files(paths)

  def exported_json(paths) = Hecks::Projector::Exporter.worlds_json(paths)

  def strings_in(value)
    case value
    when String then [value]
    when Array then value.flat_map { |item| strings_in(item) }
    when Hash then value.flat_map { |key, item| strings_in(key) + strings_in(item) }
    else []
    end
  end

  def world_shape(world)
    scalars = %w[realm latest default_adapter].all? { |key| world[key].nil? || world[key].is_a?(String) }
    [world.keys, world["domain"].is_a?(String), scalars, [true, false].include?(world["default_database"])]
  end

  def binding_shape(binding)
    [binding.keys, binding.values_at("verb", "adapter").all?(String), binding["settings"].all?(String)]
  end

  def real_worlds = exported(WORLD_PARITY_FILES)

  def merge_files(dir)
    first = File.join(dir, "a.world")
    second = File.join(dir, "b.world")
    File.write(first, MERGE_FIRST)
    File.write(second, MERGE_SECOND)
    [first, second]
  end

  MERGE_FIRST = <<~RUBY.freeze
    Hecks.world "Merged" do
      realm "Early"
      persisted_by "Heki", dir: "one"
      projected_by "Sqlite", database: "secret-a"
    end
  RUBY

  MERGE_SECOND = <<~RUBY.freeze
    Hecks.world "Merged" do
      latest "v2"
      default_database "postgres://user:hunter2@host/db"
      persisted_by "Heki" do
        root "two"
      end
    end
  RUBY

  it "finds every .world file, none in a vendored or build directory", :aggregate_failures do
    expect(WORLD_PARITY_FILES).not_to be_empty
    expect(WORLD_PARITY_FILES.grep(%r{/(vendor|node_modules|target)/})).to be_empty
  end

  it "exports every real world's keys, order and types" do
    expect(real_worlds.map { |world| world_shape(world) }.uniq).to eq([[WORLD_PARITY_KEYS, true, true, true]])
  end

  it "exports every real binding's keys, order and types" do
    expect(real_worlds.flat_map { |world| world["bindings"].map { |b| binding_shape(b) } }.uniq)
      .to eq([[BINDING_KEYS, true, true]])
  end

  it "leaks no setting value from any real world file", :aggregate_failures do
    expect(strings_in(real_worlds).join("\n")).not_to include("postgres://")
    expect(WORLD_PARITY_FILES.map { |path| File.read(path) }.join).to include("postgres://")
  end

  it "exports default_database as whether one is declared, not the connection" do
    expect(real_worlds.map { |world| world["default_database"] }.uniq).to contain_exactly(true, false)
  end

  context "with two files declaring one domain" do
    around do |example|
      Dir.mktmpdir("world_parity") do |dir|
        @files = merge_files(dir)
        example.run
      end
    end

    it "merges them into one world whose later bind replaces the earlier in place", :aggregate_failures do
      worlds = exported(@files)
      expect(worlds.size).to eq(1)
      expect(worlds[0].values_at("realm", "latest", "default_database")).to eq(["Early", "v2", true])
      expect(worlds[0]["bindings"].map { |b| b.values_at("verb", "settings") })
        .to eq([["persisted_by", ["root"]], ["projected_by", ["database"]]])
    end

    it "exports no setting value" do
      expect(exported_json(@files)).not_to match(/hunter2|secret-a|"one"/)
    end
  end

  context "with the Rust parser", :io do
    include_context "with the hecks-parse binary"

    def printed(paths)
      stdout, status = Open3.capture2(Hecks::Composer::Parse.binary, "world", *paths)
      raise "hecks-parse world #{paths.join(" ")} exited #{status.exitstatus}" unless status.success?

      stdout.chomp
    end

    WORLD_PARITY_FILES.each do |path|
      it "prints #{path.delete_prefix("#{Hecks::Corpus::ROOT}/")} as Ruby exports it" do
        expect(printed([path])).to eq(exported_json([path]))
      end
    end

    it "prints every file in one invocation as Ruby exports them, merging a domain across files" do
      expect(printed(WORLD_PARITY_FILES)).to eq(exported_json(WORLD_PARITY_FILES))
    end
  end
end
