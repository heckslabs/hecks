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

  it "runs the regeneration script from the checkout's root when confirmed" do
    shell = FakeCodebaseShell.new("wrote spec/fixtures/persistence_legacy\n")

    described_class.new(tree, shell: shell).regenerate(confirm: true)

    expect(shell.command).to eq([tree.path("bin/regenerate_persistence_legacy_fixtures")])
    expect(shell.asked.first[:chdir]).to eq(tree.root)
  end
end
