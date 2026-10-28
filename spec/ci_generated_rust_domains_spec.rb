require "spec_helper"
require "yaml"

# Each job that materializes the generated Rust tree (the `generated-rust` action) names the domains
# it reads, so a cold cache regenerates a handful of domains and not all of them. A job that names
# none gets every domain, and the table below says why, so a job cannot start regenerating the whole
# corpus without someone choosing it.
RSpec.describe "the generated-rust step of each workflow" do
  # The jobs that name no domains, and what each reads that needs every one.
  def names_every_domain
    {
      "cache-warm.yml#warm_main_crate"     => "saves the all-domains entry and the main crate's cargo cache for the whole tree",
      "ci-checks.yml#checks_codegen_drift" => "compares the whole regenerated tree with the committed one",
      "ci-checks.yml#checks_drift_tables"  => "rust coverage walks every generated module",
      "ci-rust-io.yml#rspec_rust_io leg a" => "rust_conformance_fuzz_spec builds and fuzzes every domain",
      "ci.yml#rspec_fuzzing"               => "rust_gap_manifest_spec reads every domain's manifest.json"
    }
  end

  def root = InMemoryDomain::ROOT

  def action = "./.github/actions/generated-rust"

  def features = Hecks::Corpus.rust_domains.map(&:feature)

  # The steps of one workflow file that use the action, each with its job and a name for it.
  def steps_of(path)
    YAML.load_file(path).fetch("jobs").flat_map do |name, job|
      job.fetch("steps", []).select { |step| step["uses"] == action }.map { |step| ["#{File.basename(path)}##{name}", job, step] }
    end
  end

  def workflow_steps = Dir.glob(File.join(root, ".github/workflows/*.yml")).flat_map { |path| steps_of(path) }

  # The feature names of rust/Cargo.toml, in its order, which the feature binary legs deal out.
  def cargo_features
    File.readlines(File.join(root, "rust/Cargo.toml"), chomp: true).filter_map { |line| line[/\A([a-z0-9_]+) = \[\]\z/, 1] }
  end

  # Every fourth feature from the leg's place, as ci-rust-io.yml's leg step deals them; `meta` is a
  # feature with no domain of its own.
  def leg_domains(leg)
    cargo_features.each_with_index.select { |_, index| (index + 1) % 4 == leg % 4 }.map(&:first) - ["meta"]
  end

  def matrix_sets(label, job)
    job.dig("strategy", "matrix", "include").to_h { |entry| ["#{label} leg #{entry["leg"]}", entry["domains"].to_s.split] }
  end

  # The domains each leg of one step names, by the leg's name; none is an empty list.
  def domain_sets(label, job, step)
    value = step.dig("with", "domains").to_s.strip
    case value
    when "" then { label => [] }
    when "${{ matrix.domains }}" then matrix_sets(label, job)
    when "${{ steps.leg_domains.outputs.names }}" then (1..4).to_h { |leg| ["#{label} leg #{leg}", leg_domains(leg)] }
    else { label => value.split(/[\s,]+/) }
    end
  end

  let(:sets) { workflow_steps.flat_map { |label, job, step| domain_sets(label, job, step).to_a }.to_h }

  it "finds the jobs that materialize the generated Rust" do
    expect(sets).not_to be_empty
  end

  it "names only domains the corpus has" do
    unknown = sets.transform_values { |names| names - features }.reject { |_, extra| extra.empty? }

    expect(unknown).to be_empty
  end

  it "names none only for the jobs that read every domain" do
    expect(sets.select { |_, names| names.empty? }.keys).to match_array(names_every_domain.keys)
  end

  it "gives each of those jobs a reason" do
    expect(names_every_domain.values).to all(match(/\S/))
  end

  it "deals every domain to one of the feature binary legs" do
    legs = sets.select { |label, _| label.include?("rust_feature_binaries") }.values.flatten

    expect(legs).to match_array(features)
  end
end
