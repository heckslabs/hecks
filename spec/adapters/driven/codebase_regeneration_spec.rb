require "spec_helper"
require "hecks/hecks/adapters/codebase/source_tree"
require "hecks/tools"
require_relative "../../support/fake_codebase_shell"

RSpec.describe Hecks::Adapters::Codebase::Regeneration do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:plan) { "hecks regenerate_corpus: regenerating 7 domain(s), in this fixed order:\n  examples/pizzas\n" }

  # Answers a fixed output and status, and remembers what was asked. The run happens in this
  # process, so what is stubbed is `Hecks::Tools.run`.
  def fake_run(out, status = 0)
    FakeCodebaseShell.new([out, status]).tap do |shell|
      allow(Hecks::Tools).to receive(:run, &shell.method(:run_tool))
    end
  end

  def regenerate(held)
    described_class.call("regenerate_corpus", held, tree)
  end

  it "only checks, into a scratch crate, when run with --check", :aggregate_failures do
    shell = fake_run(plan)

    report = regenerate({ check: { value: true }, confirm: { value: true } })

    expect(shell.asked.first[:command]).to eq(["regen_codegen_domains", "--check"])
    expect(shell.asked.first[:chdir]).to eq(tree.root)
    expect(report).to start_with("checked 7 corpus domains against a scratch crate: no drift")
  end

  it "checks, and never writes the tree, unless it is confirmed" do
    shell = fake_run(plan)

    regenerate({})

    expect(shell.asked.first[:command].last).to eq("--check")
  end

  it "regenerates into the checkout only when confirmed", :aggregate_failures do
    shell = fake_run(plan)

    report = regenerate({ confirm: { value: true } })

    expect(shell.asked.first[:command]).to eq(["regen_codegen_domains"])
    expect(report).to eq("regenerated 7 corpus domains into the checkout")
  end

  it "refuses with the difference the check found, keeping the last lines" do
    lines = (1..80).map { |number| "diff line #{number}" }.join("\n")
    fake_run("#{plan}#{lines}\n", 1)

    expect { regenerate({ check: { value: true } }) }
      .to raise_error(failure, /\A\(the last 60 of 82 lines\)\n.*diff line 80\z/m)
  end
end
