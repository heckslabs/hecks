# frozen_string_literal: true

require "spec_helper"
require "yaml"
require_relative "support/red_drill"

# The switch of the red drill is the environment alone, which CI sets from a pull request's label;
# no file in a commit turns it on.
RSpec.describe RedDrill do
  def workflow(name) = YAML.load_file(File.join(File.expand_path("..", __dir__), ".github/workflows", name))

  def rspec_job(name) = workflow("ci-rspec.yml").dig("jobs", name)

  def labelled = "contains(github.event.pull_request.labels.*.name, '#{described_class::LABEL}')"

  def label_test = "github.event_name == 'pull_request' && #{labelled}"

  describe ".on?" do
    it "is off without the variable, or with it set to anything but 1", :aggregate_failures do
      expect(described_class.on?(env: {})).to be(false)
      expect(described_class.on?(env: { "HECKS_RED_DRILL" => "0" })).to be(false)
    end

    it "is on when the variable is 1" do
      expect(described_class.on?(env: { "HECKS_RED_DRILL" => "1" })).to be(true)
    end

    it "takes no checkout to look in, so no tracked file can switch it on" do
      expect(described_class.method(:on?).parameters).to eq([%i[key env]])
    end

    it "defines no example in the drill spec while off" do
      expect(RSpec.world.example_groups.map(&:description)).not_to include("the red drill")
    end
  end

  describe "the label in CI" do
    it "sets HECKS_RED_DRILL in the rspec shards only for a pull request with the label" do
      expect(rspec_job("rspec_shard").dig("env", "HECKS_RED_DRILL")).to eq("${{ #{label_test} && '1' || '0' }}")
    end

    it "answers not attested for a labelled pull request, so its shards run on an attested tree" do
      expect(rspec_job("ci_attestation_rspec").dig("outputs", "attested"))
        .to eq("${{ #{label_test} && 'false' || steps.attest.outputs.attested }}")
    end

    it "runs CI again when a pull request is labelled or unlabelled" do
      expect(workflow("ci.yml").dig(true, "pull_request", "types")).to include("labeled", "unlabeled")
    end
  end
end
