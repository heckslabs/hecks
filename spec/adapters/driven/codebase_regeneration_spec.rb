require "spec_helper"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Regeneration do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  # Answers a fixed output and status, and remembers what was asked.
  let(:shell_class) do
    Class.new do
      attr_reader :asked

      def initialize(out, status = 0)
        (@out = out
         @status = status
         @asked = [])
      end

      def capture(*command, env: {}, chdir: nil)
        @asked << { command: command[1..], env: env, chdir: chdir }
        Hecks::Adapters::Shell::Result.new(@out, "", Struct.new(:success?, :exitstatus).new(@status.zero?, @status))
      end
    end
  end

  let(:plan) { "bin/regen_codegen_domains: regenerating 7 domain(s), in this fixed order:\n  examples/pizzas\n" }

  def regenerate(held, shell)
    described_class.call("regenerate_corpus", held, tree, shell: shell)
  end

  it "only checks, into a scratch crate, when run with --check" do
    shell = shell_class.new(plan)

    report = regenerate({ check: { value: true }, confirm: { value: true } }, shell)

    expect(shell.asked.first[:command]).to eq([tree.path("bin/regen_codegen_domains"), "--check"])
    expect(shell.asked.first[:chdir]).to eq(tree.root)
    expect(report).to start_with("checked 7 corpus domains against a scratch crate: no drift")
  end

  it "checks, and never writes the tree, unless it is confirmed" do
    shell = shell_class.new(plan)

    regenerate({}, shell)

    expect(shell.asked.first[:command].last).to eq("--check")
  end

  it "regenerates into the checkout only when confirmed" do
    shell = shell_class.new(plan)

    report = regenerate({ confirm: { value: true } }, shell)

    expect(shell.asked.first[:command]).to eq([tree.path("bin/regen_codegen_domains")])
    expect(report).to eq("regenerated 7 corpus domains into the checkout")
  end

  it "refuses with the difference the check found, keeping the last lines" do
    lines = (1..80).map { |number| "diff line #{number}" }.join("\n")
    shell = shell_class.new("#{plan}#{lines}\n", 1)

    expect { regenerate({ check: { value: true } }, shell) }
      .to raise_error(failure, /\A\(the last 60 of 82 lines\)\n.*diff line 80\z/m)
  end
end
