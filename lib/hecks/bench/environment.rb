require "etc"
require "open3"

module Hecks
  module Bench
    # A description of the machine and toolchain a benchmark ran on.
    #
    # A number without its hardware is not reproducible, so every report carries
    # this. Each probe is best effort: a missing tool becomes `"unknown"` rather
    # than an error, since the benchmark itself is still valid without it.
    module Environment
      module_function

      # Collects the machine and toolchain facts a report should carry.
      #
      # @return [Hash{Symbol => Object}] `:cpu`, `:cores`, `:memory_gib`, `:os`, `:ruby`,
      #   `:yjit`, `:rustc`, `:cargo`, `:hecks`, `:commit` and `:load_average`
      def describe
        {
          cpu: cpu, cores: Etc.nprocessors, memory_gib: memory_gib, os: os,
          ruby: RUBY_DESCRIPTION, yjit: yjit?,
          rustc: capture("rustc", "-V"), cargo: capture("cargo", "-V"),
          hecks: Hecks::VERSION, commit: commit, load_average: load_average
        }
      end

      # Reads the one-minute load average, the quickest sign that something else was
      # busy while a benchmark ran. `Suite.call` reads it before and after and reports both.
      #
      # @return [Float, nil] the one-minute load average, or nil when it cannot be read
      def load_average
        text = RUBY_PLATFORM.include?("darwin") ? capture("sysctl", "-n", "vm.loadavg").delete("{}") : File.read("/proc/loadavg")
        text.split.first.to_f.round(2)
      rescue SystemCallError
        nil
      end

      # Names the processor.
      #
      # @return [String] the CPU model, or `"unknown"`
      def cpu
        return capture("sysctl", "-n", "machdep.cpu.brand_string") if RUBY_PLATFORM.include?("darwin")

        model = File.foreach("/proc/cpuinfo").find { |line| line.start_with?("model name") }
        model ? model.split(":", 2).last.strip : "unknown"
      rescue SystemCallError
        "unknown"
      end

      # Reads installed memory.
      #
      # @return [Float, String] physical memory in GiB, or `"unknown"`
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

      # Names the operating system.
      #
      # @return [String] the OS name and version, or `"unknown"`
      def os
        return "macOS #{capture('sw_vers', '-productVersion')} (#{capture('uname', '-m')})" if RUBY_PLATFORM.include?("darwin")

        capture("uname", "-sr")
      end

      # Says whether Ruby's `YJIT` compiler was running.
      #
      # @return [Boolean] true when `YJIT` is enabled in this process
      def yjit?
        defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false
      end

      # Names the Hecks source revision under test.
      #
      # @return [String] the short commit hash, or `"unknown"` outside a git checkout
      def commit
        capture("git", "-C", File.expand_path("../../..", __dir__), "rev-parse", "--short", "HEAD")
      end

      # Runs a command and returns its first line of output.
      #
      # @param command [Array<String>] the program and its arguments
      # @return [String] the trimmed first line of stdout, or `"unknown"` if it cannot run
      def capture(*command)
        out, status = Open3.capture2(*command, err: File::NULL)
        status.success? && !out.strip.empty? ? out.lines.first.strip : "unknown"
      rescue SystemCallError
        "unknown"
      end
    end
  end
end
