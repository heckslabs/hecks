# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/rust_build"
require "hecks/rust_build/project_rust"
require "hecks/tools/regeneration_run"

# A corpus run regenerates each domain into one shared workspace. What it writes for a domain must
# not depend on which domains ran before it, so each domain's output can be produced, kept and
# restored on its own. Banking and compliance both attach Governance: before, Governance's files
# named whichever of them ran last, and `mod.rs` and Cargo's `default` followed the last domain too.
RSpec.describe "regenerating the corpus in any order", :io do
  # The two orders are generated once for the whole group: each is a real `hecks project_rust` run.
  before(:context) do
    @banking_first = Dir.mktmpdir("regen-order-banking-first")
    @compliance_first = Dir.mktmpdir("regen-order-compliance-first")
    @declared = Hecks::Tools::RegenerationRun.declared_flags
    @governance_by_banking = run_in_order(@banking_first, "examples/banking", "examples/compliance")
    @governance_by_compliance = run_in_order(@compliance_first, "examples/compliance", "examples/banking")
    @skipped_meta = skipped_meta
    @side_by_side = Dir.mktmpdir("regen-order-side-by-side")
    run_side_by_side(@side_by_side, %w[banking compliance].map { |name| File.join(Hecks::RustBuild::ROOT, "examples", name) })
  end

  after(:context) do
    FileUtils.rm_rf([@banking_first, @compliance_first, @side_by_side, @skipped_meta].compact)
  end

  # A workspace holding only banking, generated with `--skip-meta` as a corpus run's children are.
  def skipped_meta
    Dir.mktmpdir("regen-skip-meta").tap do |workspace|
      seed(workspace)
      regenerate(workspace, "examples/banking", Hecks::RustBuild::ProjectRust::Meta::SKIP_FLAG)
    end
  end

  # Generates the domains in one workspace the way a corpus run does: both at once, each told to
  # leave `mod.rs` and Cargo.toml alone, which the run then writes once. Banking and compliance
  # both attach Governance, so they write its files at the same time.
  def run_side_by_side(workspace, domains)
    seed(workspace)
    regeneration = Hecks::Tools::RegenerationRun
    printed = StringIO.new
    $stdout = printed
    regeneration.with_rust_dir(workspace) { regeneration.regenerate(domains, workers: domains.size) }
  ensure
    $stdout = STDOUT
  end

  # A workspace holding what a checkout's `rust/` holds that `hecks project_rust` rewrites.
  def seed(workspace)
    FileUtils.mkdir_p(File.join(workspace, "src/generated"))
    FileUtils.cp(File.join(Hecks::RustBuild::ROOT, "rust/Cargo.toml"), workspace)
  end

  def regenerate(workspace, domain, *extra)
    result = Hecks::RustBuild.in_workspace(workspace) do
      Hecks::RustBuild.capture("project_rust", [File.join(Hecks::RustBuild::ROOT, domain), *@declared, *extra])
    end
    raise "hecks project_rust #{domain} failed:\n#{result.err}\n#{result.out}" unless result.ok?
  end

  # Runs the two domains in order; answers Governance's files as the first one left them.
  def run_in_order(workspace, first, second)
    seed(workspace)
    regenerate(workspace, first)
    after_first = tree(File.join(workspace, "src/generated/governance"))
    regenerate(workspace, second)
    after_first
  end

  # Every file under `dir`, by its path relative to it.
  def tree(dir)
    Dir.glob(File.join(dir, "**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{dir}/"), File.read(path)] }
  end

  def generated(workspace) = tree(File.join(workspace, "src/generated"))
  def cargo(workspace) = File.read(File.join(workspace, "Cargo.toml"))

  it "writes the same generated tree and mod.rs whichever domain runs first", :aggregate_failures do
    expect(generated(@banking_first).keys).to include("mod.rs", "governance/metadata.rs", "banking/merged.rs")
    expect(generated(@banking_first)).to eq(generated(@compliance_first))
  end

  it "writes the same Cargo.toml whichever domain runs first" do
    expect(cargo(@banking_first)).to eq(cargo(@compliance_first))
  end

  it "writes the same tree and mod.rs when the domains are generated side by side", :aggregate_failures do
    expect(generated(@side_by_side).keys).to include("mod.rs", "governance/metadata.rs", "banking/merged.rs")
    expect(generated(@side_by_side)).to eq(generated(@banking_first))
  end

  it "writes the same Cargo.toml when the domains are generated side by side" do
    expect(cargo(@side_by_side)).to eq(cargo(@banking_first))
  end

  it "writes meta in a run of one domain, and once for a corpus run, with the same bytes", :aggregate_failures do
    expect(generated(@banking_first).keys).to include("meta/merged.rs", "meta/ir.json")
    expect(generated(@side_by_side).select { |path, _| path.start_with?("meta/") })
      .to eq(generated(@banking_first).select { |path, _| path.start_with?("meta/") })
  end

  it "leaves meta out of a domain told to skip it" do
    expect(generated(@skipped_meta).keys.grep(%r{\Ameta/})).to be_empty
  end

  it "still writes the domain that was told to skip meta" do
    expect(generated(@skipped_meta).keys).to include("banking/merged.rs")
  end

  it "leaves no temp file where it wrote side by side" do
    expect(Dir.glob(File.join(@side_by_side, "**/*.tmp-*"), File::FNM_DOTMATCH)).to be_empty
  end

  it "gives a shared bluebook the same files whichever domain generated it", :aggregate_failures do
    expect(@governance_by_banking).not_to be_empty
    expect(@governance_by_banking).to eq(@governance_by_compliance)
  end

  it "labels a shared bluebook by its own name, not by whoever attached it" do
    header = @governance_by_banking.values.filter_map { |text| text[/GENERATED by hecks project_rust from .*/] }.uniq

    expect(header).to eq(["GENERATED by hecks project_rust from Governance's canonical IR."])
  end

  it "keeps Cargo's default where the corpus declared it" do
    default = @declared.find { |flag| flag.start_with?("--default=") }.delete_prefix("--default=")

    expect(cargo(@banking_first)).to include(%(default = ["#{default}"]))
  end
end
