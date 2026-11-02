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
  corpus_root = File.expand_path("fixtures", __dir__)

  # Ruby's wiring refusals carry no code, only a message; the corpus names each refusal by code.
  refusal_codes = {
    /which no driving adapter answers to/ => "driven_by.outside_set"
  }.freeze

  def accepted_outcome(registry)
    ir = JSON.parse(JSON.generate(Hecks::Projector::Exporter.call(registry).values.first))
    entities = ir.fetch("aggregates").flat_map do |aggregate|
      (aggregate["entities"] || []).map do |entity|
        {
          "aggregate" => aggregate["name"],
          "entity" => entity["name"],
          "preconditions" => entity["preconditions"].map do |precondition|
            { "description" => precondition["description"], "canonical" => precondition["canonical"] }
          end
        }
      end
    end
    { "outcome" => "accepted", "entities" => entities }
  end

  def corpus_outcome(input_dir, refusal_codes)
    Dir.mktmpdir("parity") do |dir|
      FileUtils.cp_r(Dir.glob(File.join(input_dir, "*")), dir)
      if Dir.glob(File.join(dir, "*.hecksagon")).any?
        # A booted domain has no bluebook entities to compare, so acceptance is the whole outcome.
        Hecks.boot(dir, install_driving: false)
        { "outcome" => "accepted" }
      else
        accepted_outcome(Hecks::Codemod.load_bluebook(Dir.glob(File.join(dir, "*.bluebook")).min))
      end
    end
  rescue Hecks::Runtime::WiringError => error
    code = refusal_codes.find { |pattern, _| error.message.match?(pattern) }&.last
    raise unless code

    { "outcome" => "refused", "code" => code }
  end

  fixtures = Dir.glob(File.join(corpus_root, "**", "expected.json")).sort

  it "has fixtures to run" do
    expect(fixtures).not_to be_empty
  end

  fixtures.each do |expected_path|
    relative = expected_path.delete_prefix("#{corpus_root}/").delete_suffix("/expected.json")

    it "matches expected.json for #{relative}" do
      expected = JSON.parse(File.read(expected_path))
      actual = corpus_outcome(File.join(File.dirname(expected_path), "input"), refusal_codes)

      expect(actual).to eq(expected)
    end
  end
end
