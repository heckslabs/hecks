# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/rust_build"
require "hecks/rust_build/project_rust"
require "hecks/tools/regeneration_run"

# A job that reads two domains of the generated tree regenerates only those two. Each run is told
# every declared domain and that it is partial, so `mod.rs` and Cargo's features stay as committed.
RSpec.describe "regenerating some of the corpus's domains", :io do
  # The domains are generated once for the whole group, into a workspace seeded with the committed
  # `mod.rs` and Cargo.toml, as a checkout holds them.
  before(:context) do
    root = Hecks::RustBuild::ROOT
    @workspace = Dir.mktmpdir("regen-subset")
    FileUtils.mkdir_p(File.join(@workspace, "src/generated"))
    FileUtils.cp(File.join(root, "rust/Cargo.toml"), @workspace)
    FileUtils.cp(File.join(root, "rust/src/generated/mod.rs"), File.join(@workspace, "src/generated"))
    @mod_before = File.binread(File.join(@workspace, "src/generated/mod.rs"))
    @cargo_before = File.binread(File.join(@workspace, "Cargo.toml"))
    named = Hecks::Corpus.rust_domains_named(%w[nested_pieces lease_clock])
    @domains = named.map { |domain| domain.dir.delete_prefix("#{root}/") }
    regeneration = Hecks::Tools::RegenerationRun
    regeneration.with_rust_dir(@workspace) { regeneration.regenerate(@domains, partial: true) }
  end

  after(:context) { FileUtils.rm_rf(@workspace) }

  # Every file under `dir`, by its path relative to it.
  def tree(dir)
    Dir.glob(File.join(dir, "**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{dir}/"), File.binread(path)] }
  end

  def written = Dir.children(File.join(@workspace, "src/generated")).sort

  # The modules the named domains own, which a regeneration of the whole corpus writes as this run
  # does. The bluebooks they attach (governance) and the grammar (meta) are shared: the corpus's last
  # writer leaves them, so a run of some domains leaves them as its own last writer wrote them.
  def held_in_checkout
    %w[lease_clock nested_pieces].select do |name|
      File.exist?(File.join(Hecks::RustBuild::ROOT, "rust/src/generated", name, "ir.json"))
    end
  end

  it "writes only the named domains, the bluebooks they attach and the grammar every run writes" do
    expect(written).to eq(%w[governance lease_clock meta mod.rs nested_pieces])
  end

  it "runs the named domains in the corpus's order whatever order they were named in" do
    expect(@domains).to eq(%w[qa/stress_domains/lease_clock qa/stress_domains/nested_pieces])
  end

  it "leaves mod.rs and Cargo.toml byte-identical to the committed ones", :aggregate_failures do
    expect(File.binread(File.join(@workspace, "src/generated/mod.rs"))).to eq(@mod_before)
    expect(File.binread(File.join(@workspace, "Cargo.toml"))).to eq(@cargo_before)
  end

  it "writes what a regeneration of the whole corpus wrote, where the checkout holds one", :aggregate_failures do
    checkout = File.join(Hecks::RustBuild::ROOT, "rust/src/generated")

    held_in_checkout.each do |name|
      expect(tree(File.join(@workspace, "src/generated", name))).to eq(tree(File.join(checkout, name))), name
    end
  end
end
