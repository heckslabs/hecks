require "spec_helper"
require "hecks/hecks/adapters/codebase/source_tree"
require_relative "../../support/fake_codebase_shell"

RSpec.describe Hecks::Adapters::Codebase::Codemods do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def codemod(operation, held, shell)
    described_class.call(operation, held, tree, shell: shell)
  end

  it "rehearses hoisting with --dry-run, and says nothing was kept, unless confirmed" do
    shell = FakeCodebaseShell.new("clean (no candidates): examples/pizzas\n")

    report = codemod("hoist_local_givens", {}, shell)

    expect(report).to start_with("dry run, nothing kept (add --confirm to rewrite):")
    expect(shell.command).to eq([tree.path("bin/codemod_hoist_local_givens"), "--dry-run"])
    expect(shell.asked.first[:chdir]).to eq(tree.root)
  end

  it "lets the script keep its edits when confirmed" do
    shell = FakeCodebaseShell.new("APPLIED  examples/banking\n")

    report = codemod("hoist_local_givens", { confirm: { value: true } }, shell)

    expect(report).to eq("APPLIED  examples/banking")
    expect(shell.command).to eq([tree.path("bin/codemod_hoist_local_givens")])
  end

  it "runs the implicit append field script for the second codemod" do
    shell = FakeCodebaseShell.new("clean\n")

    codemod("drop_implicit_append_fields", { confirm: { value: true } }, shell)

    expect(shell.command).to eq([tree.path("bin/codemod_implicit_append_fields")])
  end

  it "refuses with what the script printed when it ends badly" do
    shell = FakeCodebaseShell.new(["boot failed\n", 1])

    expect { codemod("hoist_local_givens", { confirm: { value: true } }, shell) }.to raise_error(failure, "boot failed")
  end
end
