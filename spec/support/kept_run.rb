# frozen_string_literal: true

require "json"

# What a spec of a kept run reads and sends, over the reaping fleet: the run's record, and a
# `Tidy` at a named time (the clock's own when none is given).
module KeptRun
  REFUSAL = "a kept run is reviewed again once its wait has passed"

  def held = JSON.parse(launch("agent_run.tidyable")).find { |row| row["run"] == "r-done" }

  def tidy(*at) = launch("agent_run.tidy!", "to=r-done", *at.map { |time| "now.value=#{time}" }, "--wait")
end
