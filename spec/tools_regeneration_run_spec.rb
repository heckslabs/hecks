require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools"
require "hecks/rust_build/project_rust"
require "hecks/tools/regeneration_run"

# `regen_codegen_domains --check` projects into a scratch crate and always removes it.
RSpec.describe Hecks::Tools::RegenerationRun do
  let(:root) { Dir.mktmpdir("regen_root") }
  let(:scratches) { [] }

  before do
    FileUtils.mkdir_p(File.join(root, "rust/src/generated/meta"))
    File.write(File.join(root, "rust/Cargo.toml"), "[features]\n")
    allow(described_class).to receive(:plan).and_return(["examples/pizzas"])
    allow(described_class).to receive(:scratch_crate).and_wrap_original do |original, *args|
      original.call(*args).tap { |path| scratches << path }
    end
  end

  after do
    FileUtils.rm_rf(root)
    scratches.each { |path| FileUtils.rm_rf(path) }
  end

  it "refuses a check on a checkout whose generated output was never materialized" do
    FileUtils.rm_rf(File.join(root, "rust/src/generated/meta"))

    expect { described_class.main(["--check"], root: root) }.to raise_error(SystemExit)
  end

  it "removes the scratch crate when a domain aborts the run", :aggregate_failures do
    allow(described_class).to receive(:regenerate).and_raise(SystemExit.new(1))

    expect { described_class.main(["--check"], root: root) }.to raise_error(SystemExit)

    expect(scratches.size).to eq(1)
    expect(Dir.exist?(scratches.first)).to be(false)
  end

  it "removes the scratch crate when a domain raises", :aggregate_failures do
    allow(described_class).to receive(:regenerate).and_raise(RuntimeError, "boom")

    expect { described_class.main(["--check"], root: root) }.to raise_error("boom")

    expect(Dir.exist?(scratches.first)).to be(false)
  end

  describe "naming the domains to regenerate" do
    let(:checkout) { Hecks::Corpus::ROOT }

    before { allow(described_class).to receive(:plan).and_call_original }

    it "reads the domains off the `domains=` argument, and nothing when it is not given", :aggregate_failures do
      expect(described_class.named(["--check", "domains=lease_clock,nested_pieces"])).to eq(%w[lease_clock nested_pieces])
      expect(described_class.named(["--check"])).to be_nil
    end

    # What `plan` answers, its printed plan kept out of the example's output.
    def planned(*)
      answer = nil
      expect { answer = described_class.plan(checkout, *) }.to output(/regenerating \d+ domain/).to_stdout
      answer
    end

    it "plans the named domains in the corpus's fixed order whatever order they are named in" do
      expect(planned(%w[nested_pieces lease_clock])).to eq(%w[qa/stress_domains/lease_clock qa/stress_domains/nested_pieces])
    end

    it "plans every domain when none is named" do
      expect(planned.size).to eq(Hecks::Corpus.rust_regen_order.size)
    end

    it "refuses a domain that is not one, naming the valid ones", :aggregate_failures do
      expect { described_class.plan(checkout, %w[lease_clock no_such_domain]) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(/unknown domain\(s\) no_such_domain; valid: .*lease_clock.*nested_pieces/).to_stderr
    end

    it "tells a partial run so, and a whole one not", :aggregate_failures do
      expect(described_class.declared_flags(partial: true)).to end_with("--partial")
      expect(described_class.declared_flags).not_to include("--partial")
    end

    it "declares every domain to a partial run, so the others stay in mod.rs and Cargo's features" do
      declared = described_class.declared_flags(partial: true).find { |flag| flag.start_with?("--declared=") }

      expect(declared.delete_prefix("--declared=").split(",")).to include("lease_clock", "banking", "pizzas", "meta")
    end

    it "runs a named subset as a partial run, and a check of it too", :aggregate_failures do
      allow(described_class).to receive(:plan).and_return(["qa/stress_domains/lease_clock"])
      allow(described_class).to receive(:regenerate)

      described_class.main(["domains=lease_clock"], root: root)

      expect(described_class).to have_received(:regenerate)
        .with(["qa/stress_domains/lease_clock"], partial: true, workers: Etc.nprocessors)
    end

    it "runs a whole regeneration as a whole run", :aggregate_failures do
      allow(described_class).to receive(:plan).and_return(["examples/pizzas"])
      allow(described_class).to receive(:regenerate)

      described_class.main([], root: root)

      expect(described_class).to have_received(:regenerate).with(["examples/pizzas"], partial: false, workers: Etc.nprocessors)
    end
  end

  describe "generating the domains side by side" do
    let(:pool) { instance_double(Hecks::Tools::RegenerationRun::Pool, call: nil) }

    before do
      allow(Hecks::Bluebook::MetaValidator).to receive(:grammar_registry)
      allow(Hecks::Tools::RegenerationRun::Pool).to receive(:new).and_return(pool)
      allow(described_class).to receive(:write_manifest)
    end

    it "generates one domain per core unless told how many", :aggregate_failures do
      expect(described_class.workers_in([])).to eq(Etc.nprocessors)
      expect(described_class.workers_in(["workers=3"])).to eq(3)
    end

    it "refuses a number of workers that is not a whole number above zero", :aggregate_failures do
      %w[0 -1 two 1.5].each do |given|
        expect { described_class.workers_in(["workers=#{given}"]) }
          .to raise_error(SystemExit).and output(/workers=#{given} is not a positive whole number/).to_stderr
      end
    end

    def corpus_job = Hecks::Tools::RegenerationRun::CORPUS_JOB
    def skip_meta = Hecks::RustBuild::ProjectRust::Meta::SKIP_FLAG
    def project_rust = Hecks::Tools::RegenerationRun::Pool::PROJECT_RUST

    it "gives every child the declared domains and tells it to leave mod.rs and Cargo.toml alone", :aggregate_failures do
      described_class.regenerate(%w[examples/pizzas], workers: 2)

      expect(Hecks::Tools::RegenerationRun::Pool).to have_received(:new)
        .with(["meta", "examples/pizzas"], [*described_class.declared_flags(partial: true), skip_meta], 2, runner: corpus_job)
      expect(described_class.declared_flags(partial: true)).to end_with("--partial")
    end

    it "generates meta once, as the first job of the run, and tells every domain to skip it", :aggregate_failures do
      described_class.regenerate(%w[examples/pizzas examples/banking], partial: true, workers: 2)

      expect(Hecks::Tools::RegenerationRun::Pool).to have_received(:new).once
      expect(Hecks::Tools::RegenerationRun::Pool)
        .to have_received(:new).with(["meta", "examples/pizzas", "examples/banking"], include(skip_meta), 2, runner: corpus_job)
    end

    it "runs the meta job through Meta.generate, once, and not through hecks project_rust", :aggregate_failures do
      allow(Hecks::RustBuild::ProjectRust::Meta).to receive(:generate)
      allow(project_rust).to receive(:call)

      expect(corpus_job.call(["meta", "--partial"])).to eq(0)
      expect(Hecks::RustBuild::ProjectRust::Meta).to have_received(:generate).once
      expect(project_rust).not_to have_received(:call)
    end

    it "runs any other job through hecks project_rust, leaving meta alone", :aggregate_failures do
      allow(Hecks::RustBuild::ProjectRust::Meta).to receive(:generate)
      allow(project_rust).to receive(:call).and_return(0)

      expect(corpus_job.call(["examples/pizzas", skip_meta])).to eq(0)
      expect(Hecks::RustBuild::ProjectRust::Meta).not_to have_received(:generate)
    end

    it "writes mod.rs and Cargo.toml once, after the domains, when it ran them all" do
      described_class.regenerate(%w[examples/pizzas], workers: 2)

      expect(described_class).to have_received(:write_manifest).once
    end

    it "leaves mod.rs and Cargo.toml to a run of the whole corpus when it ran only some" do
      described_class.regenerate(%w[examples/pizzas], partial: true, workers: 2)

      expect(described_class).not_to have_received(:write_manifest)
    end

    it "does not write them when a domain failed", :aggregate_failures do
      allow(pool).to receive(:call).and_raise(SystemExit.new(1))

      expect { described_class.regenerate(%w[examples/pizzas]) }.to raise_error(SystemExit)
      expect(described_class).not_to have_received(:write_manifest)
    end
  end

  it "leaves the workspace as it was after an aborted check", :aggregate_failures do
    before = Hecks::RustBuild.rust_dir
    allow(described_class).to receive(:regenerate).and_raise(SystemExit.new(1))

    expect { described_class.main(["--check"], root: root) }.to raise_error(SystemExit)

    expect(Hecks::RustBuild.rust_dir).to eq(before)
  end
end
