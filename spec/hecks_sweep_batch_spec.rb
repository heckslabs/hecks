require "spec_helper"

# Small wording, rename and docs items wait in Tickets' `sweep` category and never start alone.
# Delegate's SweepBatch reads the waiting ones (this spec stands in for the queue, handing the
# reading its facts) and composes one batch work item once six wait or the oldest has waited a day;
# landing the batch closes every member still in it, and a member returned goes back alone.
RSpec.describe "sweep batches" do
  let(:hecks) { boot_hecks_in_memory }

  def cli_text(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: argv)
    out
  end

  def tickets(*argv) = JSON.parse(cli_text("tickets", *argv))

  def sweep(key)
    tickets("work.plan!", "work.value=#{key}", "title.value=Wording #{key}", "detail.value=Spec #{key}",
            "area=docs/#{key}.md")
    cli_text("tickets", "work.categorize!", "to=#{key}", "category.value=sweep")
  end

  # The queue's reading: the waiting count and the oldest's hours, against a batch of six and a day.
  def read(waiting, waited: 1)
    cli_text("sweep_batch.read!", "batch.value=sweep-batch-1", "waiting=#{waiting}", "size=6",
             "waited=#{waited}", "patience=24", "title.value=Sweep", "brief.value=#{brief}")
  end

  def brief = tickets("work.sweep_waiting").map { |row| row["work"] }.join(", ")

  def row(key) = tickets("work.show", "work=#{key}")

  def status(key) = tickets("work.undone").find { |found| found["work"] == key }&.fetch("status")

  def batch_of(count)
    (1..count).each { |n| sweep("s#{n}") }
    read(count)
  end

  def land_batch = tickets("work.close!", "to=sweep-batch-1", "landing.value=abc1234")

  it "starts nothing while five sweep items wait" do
    batch_of(5)

    expect(tickets("work.undone").map { |found| found["work"] }).not_to include("sweep-batch-1")
  end

  it "composes one batch work item naming all six on the sixth", :aggregate_failures do
    batch_of(6)
    planned = tickets("work.undone").find { |found| found["work"] == "sweep-batch-1" }

    expect(planned["detail"]).to eq((1..6).map { |n| "s#{n}" }.join(", "))
    expect(planned["priority"]).to eq("next")
  end

  it "enlists every member in the batch" do
    batch_of(6)

    expect((1..6).map { |n| status("s#{n}") }.uniq).to eq(["batched"])
  end

  it "composes a short batch once its oldest has waited a day" do
    (1..2).each { |n| sweep("s#{n}") }
    read(2, waited: 25)

    expect(status("s1")).to eq("batched")
  end

  it "closes every member still in the batch when the batch lands", :aggregate_failures do
    batch_of(6)
    cli_text("tickets", "work.return!", "to=s3", "reason.value=the paragraph moved")
    land_batch

    expect(tickets("work.undone").map { |found| found["work"] }).to eq(["s3"])
    expect(status("s3")).to eq("planned")
  end

  it "refuses to start a sweep item alone" do
    sweep("s1")
    text = cli_text("tickets", "work.start!", "to=s1", "claimed_by.value=a", "claimed_at.value=2026-11-19T09:00:00Z")

    expect(text).to include("a sweep item starts only in its batch")
  end

  it "refuses a sweep item that names no path" do
    tickets("work.plan!", "work.value=bare", "title.value=Bare")

    text = cli_text("tickets", "work.categorize!", "to=bare", "category.value=sweep")

    expect(text).to include("a sweep item names the paths it edits")
  end

  it "refuses to enlist an item that is not a sweep item" do
    tickets("work.plan!", "work.value=code", "title.value=Code")
    text = cli_text("tickets", "work.enlist!", "to=code", "batch.value=sweep-batch-1")

    expect(text).to include("only a sweep item joins a batch")
  end

  it "refuses to enlist an item already in a batch" do
    batch_of(6)

    expect(cli_text("tickets", "work.enlist!", "to=s1", "batch.value=sweep-batch-2")).to include("batched")
  end
end
