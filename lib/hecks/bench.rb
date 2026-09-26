module Hecks
  # The throughput and latency harness `bin/bench` drives.
  #
  # It dispatches a fixed, valid command workload against the Ruby runtime on each
  # persistence adapter and against the native Rust binary, and reports
  # commands per second plus p50 and p99 latency for each. Not required by
  # `lib/hecks.rb` on purpose: a booted domain never needs it.
  #
  # ## What is measured
  #
  # Every runtime is driven the same way: one caller, one command at a time, each
  # waiting for the previous answer. The Ruby side times `dispatch_flat` in-process.
  # The Rust side times a full round trip over the pipes of `rust --serve`. See
  # `docs/benchmarks.md` for what that does and does not compare.
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
require_relative "bench/suite"
require_relative "bench/report"
require_relative "bench/cli"
