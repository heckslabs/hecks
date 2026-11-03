require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "hecks/codemod"

# Runs every fixture under spec/parity/fixtures through the Ruby loader and compares the
# normalized outcome with its expected.json. rust/parser/tests/parity.rs iterates the same
# directory, so a fixture that passes here and fails there is a parity divergence.
#
# A fixture directory holds input/ and expected.json. input/ is either a bluebook file (loaded
# with Codemod) or a domain with a .hecksagon (booted, which runs the wiring checks).
RSpec.describe "parser parity corpus, Ruby side" do
  # Ruby's wiring refusals carry no code, only a message; the corpus names each refusal by code.
  def refusal_codes
    { /which no driving adapter answers to/ => "driven_by.outside_set" }
  end

  def corpus_root
    File.expand_path("fixtures", __dir__)
  end

  def fixture_paths
    Dir.glob(File.join(corpus_root, "**", "expected.json"))
  end

  def preconditions_of(entity)
    entity["preconditions"].map do |precondition|
      { "description" => precondition["description"], "canonical" => precondition["canonical"] }
    end
  end

  def entities_of(document)
    document.fetch("aggregates").flat_map do |aggregate|
      (aggregate["entities"] || []).map do |entity|
        { "aggregate" => aggregate["name"], "entity" => entity["name"], "preconditions" => preconditions_of(entity) }
      end
    end
  end

  def accepted_outcome(registry)
    ir = JSON.parse(JSON.generate(Hecks::Projector::Exporter.call(registry).values.first))
    { "outcome" => "accepted", "entities" => entities_of(ir) }
  end

  # A booted domain has no bluebook entities to compare, so acceptance is the whole outcome.
  def booted_outcome(dir)
    Hecks.boot(dir, install_driving: false)
    { "outcome" => "accepted" }
  end

  def bluebook_outcome(dir)
    accepted_outcome(Hecks::Codemod.load_bluebook(Dir.glob(File.join(dir, "*.bluebook")).min))
  end

  def loaded_outcome(dir)
    Dir.glob(File.join(dir, "*.hecksagon")).any? ? booted_outcome(dir) : bluebook_outcome(dir)
  end

  def refused_code(error)
    refusal_codes.find { |pattern, _| error.message.match?(pattern) }&.last
  end

  def corpus_outcome(input_dir)
    Dir.mktmpdir("parity") do |dir|
      FileUtils.cp_r(Dir.glob(File.join(input_dir, "*")), dir)
      loaded_outcome(dir)
    end
  rescue Hecks::Runtime::WiringError => e
    code = refused_code(e)
    raise unless code

    { "outcome" => "refused", "code" => code }
  end

  it "has fixtures to run" do
    expect(fixture_paths).not_to be_empty
  end

  fixture_paths.each do |expected_path|
    relative = expected_path.delete_prefix("#{File.expand_path("fixtures", __dir__)}/").delete_suffix("/expected.json")

    it "matches expected.json for #{relative}" do
      expected = JSON.parse(File.read(expected_path))
      actual = corpus_outcome(File.join(File.dirname(expected_path), "input"))

      expect(actual).to eq(expected)
    end
  end
end
