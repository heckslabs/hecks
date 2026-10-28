require "spec_helper"
require "yaml"

# The main crate's cargo cache is keyed on its generated sources, so each set of domains a job
# regenerates is a key of its own, and a saved copy is about two gigabytes. The repository's cache
# is limited, and a copy per set evicts the entries every job restores.
RSpec.describe "the cargo cache of the main crate" do
  def root = InMemoryDomain::ROOT

  def cargo_cache = "./.github/actions/cargo-cache"

  # The jobs allowed to save: the one that regenerates every domain for the warm cache, and leg a of
  # the Rust io job, which regenerates every domain too (its `save` is the leg's own test).
  def savers = ["cache-warm.yml#warm_main_crate", "ci-rust-io.yml#rspec_rust_io"]

  def saving_steps_of(path)
    YAML.load_file(path).fetch("jobs").flat_map do |name, job|
      job.fetch("steps", []).select { |step| main_cache?(step) && saves?(step) }.map { "#{File.basename(path)}##{name}" }
    end
  end

  def main_cache?(step) = step["uses"] == cargo_cache && step.dig("with", "name") == "main"

  def saves?(step) = step.dig("with", "save").to_s != "false"

  it "is saved only by the jobs that regenerate every domain" do
    saving = Dir.glob(File.join(root, ".github/workflows/*.yml")).flat_map { |path| saving_steps_of(path) }

    expect(saving.uniq).to match_array(savers)
  end

  it "has the Rust io job save it from leg a alone" do
    steps = YAML.load_file(File.join(root, ".github/workflows/ci-rust-io.yml")).dig("jobs", "rspec_rust_io", "steps")

    expect(steps.select { |step| main_cache?(step) }.map { |step| step.dig("with", "save") }).to eq(["${{ matrix.leg == 'a' }}"])
  end
end
