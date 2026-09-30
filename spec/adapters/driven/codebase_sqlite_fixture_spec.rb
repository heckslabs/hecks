require "spec_helper"
require "hecks/hecks/adapters/codebase/source_tree"
require_relative "../../support/fake_codebase_shell"

RSpec.describe Hecks::Adapters::Codebase::SqliteFixture do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }

  it "reports what it would rewrite and starts no script unless confirmed" do
    shell = FakeCodebaseShell.new("3.40.1\n")

    report = described_class.new(tree, shell: shell).regenerate(confirm: false)

    expect(report).to eq("dry run, would rewrite spec/fixtures/persistence_legacy/ for heki, sqlite, d1, postgres, " \
                         "postgres_era through the real adapters (sqlite3 is installed; add --confirm)")
    expect(shell.asked.map { |ask| ask[:program] }).to eq(["sqlite3"])
  end

  it "says when the sqlite3 program is missing" do
    shell = FakeCodebaseShell.new(["", 127])

    expect(described_class.new(tree, shell: shell).regenerate(confirm: false)).to include("sqlite3 is not installed")
  end

  it "regenerates in this process, into the checkout's fixture directory, when confirmed" do
    written = []
    regenerator = lambda do |dir:|
      written << dir
      "wrote #{dir}"
    end

    report = described_class.new(tree, shell: FakeCodebaseShell.new, regenerator: regenerator).regenerate(confirm: true)

    expect(written).to eq([tree.path("spec/fixtures/persistence_legacy")])
    expect(report).to eq("wrote #{tree.path('spec/fixtures/persistence_legacy')}")
  end

  it "refuses with the reason when the regeneration cannot run" do
    regenerator = ->(dir:) { raise LoadError, "cannot load such file -- pg (#{dir})" }
    fixture = described_class.new(tree, shell: FakeCodebaseShell.new, regenerator: regenerator)

    expect { fixture.regenerate(confirm: true) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /LoadError: cannot load such file -- pg/)
  end

  it "defaults to the gem's own regeneration, so an installed gem needs no bin/ script" do
    expect(described_class.new(tree).send(:regenerator)).to eq(Hecks::PersistenceLegacyFixture::Regenerate)
  end
end
