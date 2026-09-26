require "fileutils"
require "open3"
require_relative "run"

module Hecks
  module Bench
    # Measures the native Rust binary through its streaming mode.
    #
    # `rust --serve` reads one JSON step per line and answers one JSON line each, keeping
    # its in-memory store alive between them. This runner writes a step, waits for the
    # answer line, and times the whole round trip, so the figures include two pipe
    # crossings and the binary's own JSON parse and print. Process start-up is outside
    # the timer.
    #
    # Alongside each run it measures a **round-trip floor**: the same round trip for a
    # step the binary refuses immediately, which is what the pipes cost with almost no
    # domain work behind them.
    module RustRunner
      # Where the Rust crate lives.
      RUST_DIR = File.expand_path("../../../rust", __dir__)

      # How many refused-at-once steps make up the round-trip floor's sample.
      FLOOR_SAMPLES = 500

      # A `cargo build` that exited non-zero.
      class BuildFailed < StandardError; end

      # A benchmarked step the binary refused or could not answer.
      class StepRefused < StandardError; end

      module_function

      # Says why the Rust target cannot run, if it cannot.
      #
      # @param binary [String, nil] an explicit pre-built binary, which needs no toolchain
      # @return [String, nil] nil when the target can run, otherwise one sentence saying why
      def unavailable_reason(binary: nil)
        return "the binary #{binary} does not exist or is not executable" if binary && !File.executable?(binary)
        return nil if binary || Environment.capture("cargo", "-V") != "unknown"

        "`cargo` is not on PATH and no --rust-binary was given"
      end

      # Builds the release binary for one domain's Cargo feature and pins a copy of it.
      #
      # The copy has its own name so building another domain's feature afterwards cannot
      # replace it.
      #
      # @param feature [String] the domain's Cargo feature, its directory name
      # @param rust_dir [String] the Rust crate's directory
      # @return [String] the path of the pinned release binary
      # @raise [BuildFailed] if cargo exits non-zero or leaves no binary
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

      # Starts the binary in serve mode and times the workload's commands.
      #
      # @param workload [Workload] the commands to send
      # @param binary [String] the path of a binary built for `workload`'s domain
      # @param warmup [Integer] cycles sent and discarded before timing starts
      # @param iterations [Integer] cycles timed
      # @return [Run] the timings, with the round-trip floor in its extras as
      #   `:roundtrip_floor_p50_us`
      # @raise [StepRefused] if the binary refuses any step, warmup included
      def call(workload, binary:, warmup:, iterations:)
        IO.popen([binary, "--serve"], "r+") do |pipe|
          pipe.sync = true
          workload.setup.each { |step| ask(pipe, step.to_json_line) }
          warmup.times { |n| workload.cycle(n).each { |step| ask(pipe, step.to_json_line) } }
          run = measure(pipe, workload, warmup: warmup, iterations: iterations)
          Run.new(samples: run.samples, wall_seconds: run.wall_seconds,
                  extras: { roundtrip_floor_p50_us: floor(pipe) })
        ensure
          pipe.close_write unless pipe.closed?
        end
      end

      # Times the measured cycles.
      #
      # @param pipe [IO] the binary's stdin and stdout
      # @param workload [Workload] the commands to send
      # @param warmup [Integer] cycles already sent, so record names continue from there
      # @param iterations [Integer] cycles to time
      # @return [Run] the timings, without extras
      def measure(pipe, workload, warmup:, iterations:)
        samples = []
        started = now
        iterations.times do |n|
          workload.cycle(warmup + n).each do |step|
            line = step.to_json_line
            began = now
            answer = round_trip(pipe, line)
            samples << [step.verb, now - began]
            check(answer, step.verb)
          end
        end
        Run.new(samples: samples, wall_seconds: now - started)
      end

      # Measures the pipes with almost no work behind them.
      #
      # @param pipe [IO] the binary's stdin and stdout
      # @return [Float] the p50 microseconds of {FLOOR_SAMPLES} round trips for an empty step,
      #   which the binary refuses without touching its store
      def floor(pipe)
        seconds = Array.new(FLOOR_SAMPLES) do
          began = now
          round_trip(pipe, "{}")
          now - began
        end
        Stats.micros(Stats.percentile(seconds, 0.5))
      end

      # Sends one step and returns the answer line, untimed.
      #
      # @param pipe [IO] the binary's stdin and stdout
      # @param line [String] the step as one JSON line
      # @return [void]
      # @raise [StepRefused] if the binary refuses the step
      def ask(pipe, line)
        check(round_trip(pipe, line), line[0, 80])
      end

      # Writes one line and reads one line back.
      #
      # @param pipe [IO] the binary's stdin and stdout
      # @param line [String] the step as one JSON line
      # @return [String] the answer line, or an empty string if the binary closed its output
      def round_trip(pipe, line)
        pipe.write(line, "\n")
        pipe.gets.to_s
      end

      # Refuses an answer that is not a success.
      #
      # @param answer [String] the binary's answer line
      # @param what [String] what was asked, for the error message
      # @return [void]
      # @raise [StepRefused] unless `answer` starts with `{"ok":true`
      def check(answer, what)
        return if answer.start_with?('{"ok":true')

        raise StepRefused, "#{what} was not accepted: #{answer.strip.empty? ? 'the binary closed its output' : answer.strip}"
      end

      # Reads the monotonic clock.
      #
      # @return [Float] seconds on the monotonic clock
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
