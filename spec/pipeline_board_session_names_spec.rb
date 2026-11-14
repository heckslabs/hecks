# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/pipeline_jobs"

# A session shows on the board by its name. Cleanup removes a finished session from `claude
# agents`, and the board then showed only its id ("90efb0af"). The job's own `state.json` still
# holds the name.
RSpec.describe "The board's name for a session" do
  let(:dir) { Dir.mktmpdir("session-names") }

  after { FileUtils.rm_rf(dir) }

  def job(id, state)
    FileUtils.mkdir_p(File.join(dir, id))
    File.write(File.join(dir, id, "state.json"), JSON.generate({ "state" => "done", "detail" => "ok" }.merge(state)))
  end

  def named(agents)
    rows = Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, agents: -> { agents }, now: -> { Time.now } }).rows
    rows.to_h { |row| [row[:id], row[:name]] }
  end

  it "uses the name `claude agents` lists while the session is listed" do
    job("s1", "name" => "recorded-name")

    expect(named([{ "id" => "s1", "name" => "listed-name", "status" => "idle", "startedAt" => 1 }])).to eq("s1" => "listed-name")
  end

  it "uses the name the job recorded once cleanup has removed the session from the list" do
    job("90efb0af", "name" => "stall-work-item-rely-on-events")

    expect(named([])).to eq("90efb0af" => "stall-work-item-rely-on-events")
  end

  it "falls back to the id only when neither names it", :aggregate_failures do
    job("bare", {})
    job("empty", "name" => "")

    expect(named([])).to eq("bare" => "bare", "empty" => "empty")
  end
end
