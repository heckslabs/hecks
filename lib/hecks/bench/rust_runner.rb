require "fileutils"
require "open3"
require_relative "run"

module Hecks
  module Bench
    # Times the native Rust binary through `rust --serve`, one JSON step per line.
    # Timings include two pipe crossings and the binary's own JSON parse; start-up is excluded.
    module RustRunner
      # HECKS_RUST_DIR names the workspace to build in; unset, this checkout's own rust/.
      RUST_DIR = ENV.fetch("HECKS_RUST_DIR") { File.expand_path("../../../rust", __dir__) }

      FLOOR_SAMPLES = 500

      class BuildFailed < StandardError; end

      class StepRefused < StandardError; end

      module_function

      def unavailable_reason(binary: nil)
        return "the binary #{binary} does not exist or is not executable" if binary && !File.executable?(binary)
        return nil if binary || Environment.capture("cargo", "-V") != "unknown"

        "`cargo` is not on PATH and no --rust-binary was given"
      end

      # The pinned copy has its own name so building another domain's feature cannot replace it.
      def build(feature, rust_dir: RUST_DIR)
        output, status = Open3.capture2e("cargo", "build", "--release", "--no-default-features",
                                         "--features", feature, chdir: rust_dir)
        unless status.success?
          raise BuildFailed,
                "cargo build --release --features #{feature} failed:\n#{output.lines.last(15).join}"
        end

        target = File.join(ENV.fetch("CARGO_TARGET_DIR", File.join(rust_dir, "target")), "release")
        pinned = File.join(target, "rust-bench-#{feature}")
        FileUtils.cp(File.join(target, "rust"), pinned)
        pinned
      end

      def call(workload, binary:, warmup:, iterations:)
        IO.popen([binary, "--serve"], "r+") do |pipe|
          pipe.sync = true
          run = measured_run(pipe, workload, warmup, iterations)
          Run.new(samples: run.samples, wall_seconds: run.wall_seconds,
                  extras: { roundtrip_floor_p50_us: floor(pipe) })
        ensure
          pipe.close_write unless pipe.closed?
        end
      end

      def measured_run(pipe, workload, warmup, iterations)
        workload.setup.each { |step| ask(pipe, step.to_json_line) }
        warmup.times { |n| workload.cycle(n).each { |step| ask(pipe, step.to_json_line) } }
        measure(pipe, workload, warmup: warmup, iterations: iterations)
      end

      def measure(pipe, workload, warmup:, iterations:)
        samples = []
        started = now
        iterations.times do |n|
          workload.cycle(warmup + n).each { |step| samples << timed_step(pipe, step) }
        end
        Run.new(samples: samples, wall_seconds: now - started)
      end

      # @return [Array(String, Float)] the step's verb and how long its round trip took
      def timed_step(pipe, step)
        line = step.to_json_line
        began = now
        answer = round_trip(pipe, line)
        sample = [step.verb, now - began]
        check(answer, step.verb)
        sample
      end

      # An empty step is refused without touching the store: the cost of the pipes alone.
      def floor(pipe)
        seconds = Array.new(FLOOR_SAMPLES) do
          began = now
          round_trip(pipe, "{}")
          now - began
        end
        Stats.micros(Stats.percentile(seconds, 0.5))
      end

      def ask(pipe, line)
        check(round_trip(pipe, line), line[0, 80])
      end

      def round_trip(pipe, line)
        pipe.write(line, "\n")
        pipe.gets.to_s
      end

      def check(answer, what)
        return if answer.start_with?('{"ok":true')

        raise StepRefused, "#{what} was not accepted: #{answer.strip.empty? ? "the binary closed its output" : answer.strip}"
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
