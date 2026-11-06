module Hecks
  # Throughput and latency harness behind `hecks bench`; see `docs/benchmarks.md`.
  # Not required by `lib/hecks.rb`: a booted domain never needs it.
  module Bench
  end
end

require_relative "bench/stats"
require_relative "bench/workload"
require_relative "bench/environment"
require_relative "bench/postgres_probe"
require_relative "bench/run"
require_relative "bench/ruby_runner"
require_relative "bench/rust_runner"
require_relative "bench/kernel_runner"
require_relative "bench/aggregate"
require_relative "bench/gate_workloads"
require_relative "bench/gate"
require_relative "bench/gate_report"
require_relative "bench/suite"
require_relative "bench/report"
require_relative "bench/cli"
