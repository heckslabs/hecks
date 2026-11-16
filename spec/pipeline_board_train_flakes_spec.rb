# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_github"

# Flakes on train pull requests: what failed on an earlier attempt of a run that a later attempt
# of the same run passed, read from GitHub's attempt history.
RSpec.describe Hecks::Adapters::PipelineGitHub, "#train_flakes" do
  let(:today) { Time.now.utc.iso8601 }
  let(:spec_log) { "Failure/Error: x\nrspec ./spec/x_spec.rb:12 # fails\n" }

  def run(id, attempt: 2, conclusion: "success", created: today)
    { "databaseId" => id, "headBranch" => "train/main-#{id}", "attempt" => attempt, "conclusion" => conclusion,
      "createdAt" => created, "url" => "https://gh/runs/#{id}" }
  end

  def job(name, conclusion: "failure") = { "databaseId" => 5, "name" => name, "conclusion" => conclusion, "steps" => [] }

  def adapter(runs, jobs: [job("rspec_shard (3)")], log: spec_log)
    gh = ->(*args) { args[0..1] == %w[run list] ? runs : { "jobs" => jobs } }
    described_class.new(settings: { gh: gh, gh_text: ->(*) { log }, ttl: 0 })
  end

  def flakes(subject) = JSON.parse(subject.train_flakes[:text])

  it "lists the spec file that failed attempt 1 and passed on the rerun once", :aggregate_failures do
    row = flakes(adapter([run(1)]))["flakes"]
    expect(row.map { |f| [f["item"], f["kind"], f["count"]] }).to eq([["spec/x_spec.rb", "spec", 1]])
    expect(row.first["prs"].first["branch"]).to eq("train/main-1")
  end

  it "counts a file once per run and once more for another run" do
    expect(flakes(adapter([run(1), run(2)]))["flakes"].first["count"]).to eq(2)
  end

  it "does not count a run that never passed (a recurring failure)" do
    expect(flakes(adapter([run(1, conclusion: "failure")]))["flakes"]).to eq([])
  end

  it "does not count a run that passed first time" do
    expect(flakes(adapter([run(1, attempt: 1)]))["flakes"]).to eq([])
  end

  it "leaves out a run older than 14 days" do
    expect(flakes(adapter([run(1, created: "2020-01-01T00:00:00Z")]))["flakes"]).to eq([])
  end

  it "names a failure before the specs by its job" do
    row = flakes(adapter([run(1)], log: "no specs ran"))["flakes"].first
    expect([row["item"], row["kind"]]).to eq(["rspec_shard (3)", "setup"])
  end

  def half_readable
    gh = lambda do |*args|
      next [run(1), run(2)] if args[0..1] == %w[run list]

      raise Hecks::Adapters::PipelineBoard::Unavailable, "502" if args[2] == "1"

      { "jobs" => [job("a")] }
    end
    flakes(described_class.new(settings: { gh: gh, gh_text: ->(*) { spec_log }, ttl: 0 }))
  end

  it "counts the runs it could not read and still lists the rest", :aggregate_failures do
    doc = half_readable
    expect([doc["unreadable"], doc["flakes"].first["count"]]).to eq([1, 1])
  end

  # An adapter whose `gh` records each job list and log it is asked for; `fail` names the runs
  # whose job list cannot be read yet. The budget read (`gh api rate_limit`, before each read) is
  # answered empty and not recorded.
  def counting(asked, fail: [])
    gh_text = ->(*args) { (asked << args.first(5)) && spec_log }
    described_class.new(settings: { gh: counting_gh(asked, fail), gh_text: gh_text, ttl: 0 })
  end

  def counting_gh(asked, fail)
    lambda do |*args|
      next {} if args[0..1] == %w[api rate_limit]
      next [run(1), run(2)] if args[0..1] == %w[run list]
      raise Hecks::Adapters::PipelineBoard::Unavailable, "502" if fail.include?(args[2])

      asked << args.first(5)
      { "jobs" => [job("a")] }
    end
  end

  it "reads each finished attempt once, however often the flakes are read", :aggregate_failures do
    asked = []
    github = counting(asked)
    first = flakes(github)
    expect { flakes(github) }.not_to(change { asked.size })
    expect(flakes(github)).to eq(first)
  end

  # Reads the flakes while run 1's job list cannot be read, then again once it can.
  # @return [Hash] the second read
  def read_after_failure(asked)
    fail = ["1"]
    github = counting(asked, fail: fail)
    flakes(github)
    fail.clear
    flakes(github)
  end

  it "reads again an attempt that could not be read, and keeps the ones it could", :aggregate_failures do
    asked = []
    expect(read_after_failure(asked)["unreadable"]).to eq(0)
    expect(asked.select { |args| args[0] == "run" }.map { |args| args[2] }.tally).to eq("1" => 1, "2" => 1)
  end

  # An adapter whose log read fails while `state[:broken]` holds, on the clock `state[:now]`.
  def backed_off(state, logs)
    gh = ->(*args) { args[0..1] == %w[run list] ? [run(1)] : { "jobs" => [job("a")] } }
    text = lambda do |*args|
      logs << args
      raise Hecks::Adapters::PipelineBoard::Unavailable, "slow" if state[:broken]

      spec_log
    end
    described_class.new(settings: { gh: gh, gh_text: text, ttl: 0, clock: -> { state[:now] } })
  end

  def read_through_backoff(logs)
    state = { broken: true, now: 0 }
    github = backed_off(state, logs)
    2.times { flakes(github) }
    state[:broken] = false
    state[:now] = 601
    flakes(github)
  end

  it "does not ask for a log that failed lately, and asks again once the back-off ends", :aggregate_failures do
    logs = []
    expect(read_through_backoff(logs)["flakes"].size).to eq(1)
    expect(logs.size).to eq(2)
  end

  it "counts a run whose log is held back as unread" do
    github = backed_off({ broken: true, now: 0 }, [])
    expect(flakes(github)["unreadable"]).to eq(1)
  end

  it "reads the log over REST and ignores a spec file a passing step only names", :aggregate_failures do
    logs = []
    github = backed_off({ broken: false, now: 0 }, logs)
    expect(flakes(github)["flakes"].map { |f| f["item"] }).to eq(["spec/x_spec.rb"])
    expect(logs.first).to eq(["api", "repos/{owner}/{repo}/actions/jobs/5/logs"])
  end

  it "says how far back the runs reach" do
    expect(flakes(adapter([run(1)]))["reaches_back"]).to eq(today)
  end
end
