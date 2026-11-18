require "spec_helper"
require "hecks/hecks/adapters/github_branch_ci"
require_relative "support/fake_branch_ci"

# The facts one ended run answers the `BranchCi` port: every failed job in `failing`, and in
# `inherited` those whose every failed example failed on the branch's base too. The base's shards
# split the specs another way, so an example is matched across all of the base's failed jobs.
RSpec.describe Hecks::Adapters::GithubBranchCi::Verdict do
  def fake = @fake ||= FakeBranchCi.new

  def failed(id, name, *examples)
    fake.logs[id] = examples.map { |example| "rspec #{example} # fails" }.join("\n")
    { "id" => id, "name" => name, "conclusion" => "failure" }
  end

  def answer
    github = Hecks::Adapters::GithubBranchCi::GhCall.new(fake, "/tmp")
    described_class.new(github, { "id" => 99 }, Time.now.utc).answer("abcdef1234", "7")
  end

  def split_base
    fake.base_jobs = [failed(12, "rspec_1", "./spec/a_spec.rb:1"), failed(13, "rspec_2", "./spec/b_spec.rb:2")]
  end

  it "inherits a job whose examples failed in several of the base's jobs", :aggregate_failures do
    split_base
    fake.jobs = [failed(2, "rspec_3", "./spec/a_spec.rb:1", "./spec/b_spec.rb:2")]
    expect(answer[:failing][:value]).to eq("rspec_3")
    expect(answer[:inherited][:value]).to eq("rspec_3")
  end

  it "keeps a job the branch's own when one of its examples passed on the base" do
    split_base
    fake.jobs = [failed(2, "rspec_3", "./spec/a_spec.rb:1", "./spec/c_spec.rb:3")]
    expect(answer[:inherited][:value]).to eq("")
  end

  it "lists the inherited jobs in the failing jobs' order" do
    split_base
    fake.jobs = [failed(2, "x", "./spec/new_spec.rb:1"), failed(3, "y", "./spec/b_spec.rb:2"),
                 failed(4, "z", "./spec/a_spec.rb:1")]
    expect(answer[:inherited][:value]).to eq("y, z")
  end

  it "reads no base when no job failed" do
    fake.jobs = []
    answer
    expect(fake.calls).not_to include(include("merge-base"))
  end
end
