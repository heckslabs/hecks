# frozen_string_literal: true

# Every example tagged `:wall_clock`, by file and description. The registry spec
# (spec/wall_clock_registry_spec.rb) holds this list and the tags to each other, so a timing
# example cannot be added, renamed or untagged without the list saying so.
module WallClock
  EXAMPLES = [
    ["spec/cli_cold_start_budget_spec.rb", "answers a warm bare hecks under the ceiling"],
    ["spec/hecks_heartbeat_single_flight_spec.rb", "is declined in under a second"],
    ["spec/hecks_machine_history_cost_spec.rb", "scans 10,000 readings in Memory well inside the minute between readings"],
    ["spec/hecks_machine_history_cost_spec.rb", "scans 10,000 readings over SQLite inside the minute between readings"],
    ["spec/pipeline_board_plan_page_speed_spec.rb", "draws 300 Work items in under one second"],
    ["spec/record_index_spec.rb", "answers a search of 500 items in under 50 ms once indexed"],
    ["spec/resident_concurrency_spec.rb",
     "answers every line and keeps the slowest near a cold boot when every core is busy"],
    ["spec/resident_handshake_spec.rb",
     "is dropped within the one deadline of the whole exchange, and its line is not run"],
    ["spec/resident_launcher_spec.rb", "answers a line in less than half the time a cold boot takes"],
    ["spec/resident_pool_spec.rb", "ends a launcher's wait for a resident that never answers in about that time"],
    ["spec/adapters/driven/bounded_capture_spec.rb", "ends a program whose directory disappears, long before the bound"],
    ["spec/adapters/driven/claude_jobs_spec.rb", "answers at once when the job reads working"],
    ["spec/adapters/driven/claude_jobs_spec.rb", "answers at once when the woken session has already ended"],
    ["spec/adapters/driven/claude_jobs_spec.rb", "answers at once for a job that is not written yet, as a copy's is not"],
    ["spec/adapters/driven/claude_jobs_spec.rb", "gives up after the patience and answers anyway"],
    ["spec/adapters/driven/in_process_operations_spec.rb", "ends at its timeout when nothing arrives"],
    ["spec/adapters/driven/ledger_keeping_spec.rb", "returns within the wait instead of waiting for the holder"],
    ["spec/adapters/driven/memory_history_spec.rb",
     "takes about the same time per step at 200 recorded snapshots as at 20"],
    ["spec/adapters/driven/memory_nested_spec.rb",
     "takes about the same time per step with 200 cells in the value object as with 20"],
    ["spec/adapters/driven/postgres_era/field_cache_spec.rb",
     "lets a concurrent plain write through while a backfill is mid-scan"]
  ].freeze
end
