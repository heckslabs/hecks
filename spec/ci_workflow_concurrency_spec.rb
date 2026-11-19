require "spec_helper"
require "yaml"

# A coder's new push to ci/<branch> cancels the older run of the same pull request, so a superseded
# run stops spending the repository's shared Actions budget. A train/ pull request, a push to main,
# a merge_group run and a scheduled run are never cancelled: each must finish to report its checks.
#
# The reusable workflows (`on: workflow_call` only) run as jobs of their caller's run and are
# cancelled with it. A group of their own would read the caller's `github.ref`, so two main runs
# would share it and a pending one would be dropped.
RSpec.describe ".github/workflows concurrency" do
  WORKFLOWS_DIR = File.join(InMemoryDomain::ROOT, ".github/workflows")
  CANCEL_SUPERSEDED_PR = "${{ github.event_name == 'pull_request' && !startsWith(github.head_ref, 'train/') }}".freeze

  def self.workflows
    Dir[File.join(WORKFLOWS_DIR, "*.yml")].to_h { |path| [File.basename(path), YAML.load_file(path)] }
  end

  # YAML reads the bare key `on` as true.
  def self.triggers(workflow)
    on = workflow.fetch(true) { workflow.fetch("on") }
    on.is_a?(Hash) ? on.keys : Array(on)
  end

  def self.called_only = workflows.select { |_, workflow| triggers(workflow) == ["workflow_call"] }

  def self.callers_of(name)
    workflows.select { |_, workflow| workflow.fetch("jobs").values.any? { |job| job["uses"] == "./.github/workflows/#{name}" } }
  end

  def self.declares_concurrency?(workflow)
    workflow.key?("concurrency") || workflow.fetch("jobs").values.any? { |job| job.key?("concurrency") }
  end

  # ci/x cancels its older run; train/main-x, main, merge_group and schedule runs do not.
  workflows.select { |_, workflow| triggers(workflow).include?("pull_request") }.each do |name, workflow|
    it "cancels only a superseded non-train pull request run in #{name}" do
      expect(workflow.dig("concurrency", "cancel-in-progress")).to eq(CANCEL_SUPERSEDED_PR)
    end

    it "keys #{name}'s group by pull request number, so ci/ PRs do not cancel each other" do
      expect(workflow.dig("concurrency", "group").to_s).to include("github.event.pull_request.number || github.ref")
    end
  end

  called_only.each do |name, workflow|
    it "gives the called workflow #{name} no concurrency group of its own" do
      expect(self.class.declares_concurrency?(workflow)).to be(false)
    end

    it "calls #{name} only from a workflow that cancels a superseded pull request run" do
      cancels = self.class.callers_of(name).values.map { |caller| caller.dig("concurrency", "cancel-in-progress") }

      expect(cancels).to all(eq(CANCEL_SUPERSEDED_PR)).and(be_any)
    end
  end

  it "finds the eight reusable workflows ci.yml calls" do
    expect(self.class.called_only.keys.size).to eq(8)
  end
end
