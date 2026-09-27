require "etc"
require "open3"

module Hecks
  module Bench
    # Describes the machine and toolchain a benchmark ran on.
    # Each probe is best effort: a missing tool yields `"unknown"`, not an error.
    module Environment
      module_function

      def describe
        {
          cpu: cpu, cores: Etc.nprocessors, memory_gib: memory_gib, os: os,
          ruby: RUBY_DESCRIPTION, yjit: yjit?,
          rustc: capture("rustc", "-V"), cargo: capture("cargo", "-V"),
          hecks: Hecks::VERSION, commit: commit, load_average: load_average
        }
      end

      # Read before and after a run to show whether something else was busy.
      def load_average
        text = RUBY_PLATFORM.include?("darwin") ? capture("sysctl", "-n", "vm.loadavg").delete("{}") : File.read("/proc/loadavg")
        text.split.first.to_f.round(2)
      rescue SystemCallError
        nil
      end

      def cpu
        return capture("sysctl", "-n", "machdep.cpu.brand_string") if RUBY_PLATFORM.include?("darwin")

        model = File.foreach("/proc/cpuinfo").find { |line| line.start_with?("model name") }
        model ? model.split(":", 2).last.strip : "unknown"
      rescue SystemCallError
        "unknown"
      end

      def memory_gib
        bytes =
          if RUBY_PLATFORM.include?("darwin")
            capture("sysctl", "-n", "hw.memsize").to_i
          else
            File.read("/proc/meminfo")[/MemTotal:\s+(\d+)/, 1].to_i * 1024
          end
        bytes.zero? ? "unknown" : (bytes / (1024.0**3)).round(1)
      rescue SystemCallError
        "unknown"
      end

      def os
        return "macOS #{capture('sw_vers', '-productVersion')} (#{capture('uname', '-m')})" if RUBY_PLATFORM.include?("darwin")

        capture("uname", "-sr")
      end

      def yjit?
        defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false
      end

      def commit
        capture("git", "-C", File.expand_path("../../..", __dir__), "rev-parse", "--short", "HEAD")
      end

      def capture(*command)
        out, status = Open3.capture2(*command, err: File::NULL)
        status.success? && !out.strip.empty? ? out.lines.first.strip : "unknown"
      rescue SystemCallError
        "unknown"
      end
    end
  end
end
