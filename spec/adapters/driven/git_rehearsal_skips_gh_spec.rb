require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/git_rehearsal"

# A spec that fakes gh runs; only one that launches the real gh is left out, and the report names the call.
RSpec.describe Hecks::Adapters::GitRehearsal::Impacted::Skips, "#call" do
  let(:root) { Dir.mktmpdir("hecks-skips-gh") }
  let(:skips) { described_class.new(root, scratch: -> { true }) }

  after { FileUtils.remove_entry(root) }

  def spec(text) = File.write(File.join(root, "a_spec.rb"), text).then { "a_spec.rb" }

  it "leaves out a spec that runs gh in backticks" do
    expect(skips.call(spec("out = `gh pr view 1`\n"))).to eq("needs gh: out = `gh pr view 1`")
  end

  it "runs a spec whose comments say gh is a fake" do
    expect(skips.call(spec("# `gh` is a fake; `gh pr` runs nowhere\nx = 1 # gh pr list\n"))).to be_nil
  end

  it "runs a spec that fakes gh and expects its argv" do
    text = %(train = Train.new(runner: method(:github))\nexpect(calls).to eq([["gh", "pr", "merge"]])\n)
    expect(skips.call(spec(text))).to be_nil
  end

  it "reads a line with interpolation as code" do
    line = %(puts "\#{x}"; system("gh", "pr"))
    expect(skips.call(spec("#{line}\n"))).to eq("needs gh: #{line}")
  end

  it "reads a line with a trailing comment as code" do
    expect(skips.call(spec(%(system("gh", "pr") # real\n)))).to eq(%(needs gh: system("gh", "pr")))
  end

  it "runs the train specs that fake gh", :aggregate_failures do
    real = described_class.new(Dir.pwd, scratch: -> { true })
    expect(real.call("spec/pull_request_train_spec.rb")).to be_nil
    expect(real.call("spec/pull_request_train_no_auto_merge_spec.rb")).to be_nil
  end
end
