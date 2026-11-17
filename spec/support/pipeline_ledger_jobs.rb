# frozen_string_literal: true

require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/pipeline_jobs"

# Job folders and the board's reading of them, shared by the ledger examples.
module PipelineLedgerJobs
  def job(id, state = "working", extra = {})
    FileUtils.mkdir_p(File.join(dir, id))
    File.write(File.join(dir, id, "state.json"), JSON.generate({ "state" => state, "detail" => "ok" }.merge(extra)))
  end

  def rows(runs, now: Time.now)
    Hecks::Adapters::PipelineJobs.new(settings: { jobs_dir: dir, runs: -> { runs }, now: -> { now } }).rows
  end

  def past_window
    Time.now + (Hecks::Adapters::PipelineBoard::Rules.setting("session_window_hours") * 3600) + 60
  end
end
