require "open3"
require "json"

module Hecks
  class Runtime

    # Hecks::Runtime::ShellDispatcher
    #
    # Invokes a Hecksagon::Structure::ShellAdapter with runtime-provided
    # attributes, substitutes {{placeholder}} tokens in the arg vector,
    # executes via Open3.capture3 (never through a shell), parses stdout
    # according to the adapter's output_format, and returns a Result.
    #
    # Security:
    # - command is a fixed binary (Structure validates no "{{" in it)
    # - args are always an array of strings — placeholders substitute
    #   per-element; there is no shell string form
    # - env is empty by default; only entries declared on the adapter
    #   are passed through
    # - working_dir resolves from the adapter's own working_dir (caller
    #   is responsible for making it absolute before constructing the
    #   adapter, or Dir.pwd is used when it's nil)
    # - stdin is unused in v1 (no piping)
    #
    #   result = ShellDispatcher.call(adapter, range: "HEAD~5..HEAD")
    #   result.output       # => format-parsed
    #   result.raw_stdout   # => raw string
    #   result.stderr       # => raw stderr string
    #   result.exit_status  # => Integer
    #
    module ShellDispatcher
      # Return shape for a successful (or :exit_code-format) dispatch.
      Result = Struct.new(:output, :raw_stdout, :stderr, :exit_status, keyword_init: true)

      module_function

      # Dispatch a shell adapter.
      #
      # @param adapter [Hecksagon::Structure::ShellAdapter]
      # @param attrs [Hash{Symbol=>Object}] values substituted into {{placeholders}}
      # @return [Result]
      # @raise [Hecks::ShellAdapterError] if exit status is non-zero (except :exit_code format)
      # @raise [Hecks::ShellAdapterTimeoutError] if adapter.timeout is exceeded
      def call(adapter, attrs = {})
        substituted = substitute_placeholders(adapter.args, attrs)
        run(adapter, substituted)
      end

      # Substitute {{name}} tokens in each arg element from +attrs+.
      # Unknown placeholders are left as-is so callers see the literal
      # token in the executed command (helpful for debugging).
      #
      # @param args [Array<String>]
      # @param attrs [Hash]
      # @return [Array<String>]
      def substitute_placeholders(args, attrs)
        sym_attrs = attrs.transform_keys(&:to_sym)
        args.map do |arg|
          arg.gsub(Hecksagon::Structure::ShellAdapter::PLACEHOLDER_RE) do
            name = Regexp.last_match(1).to_sym
            sym_attrs.key?(name) ? sym_attrs[name].to_s : Regexp.last_match(0)
          end
        end
      end

      # Execute the adapter and return a Result.
      #
      # @param adapter [Hecksagon::Structure::ShellAdapter]
      # @param args [Array<String>]
      # @return [Result]
      def run(adapter, args)
        chdir = adapter.working_dir || Dir.pwd
        env = adapter.env
        stdout, stderr, status = capture(adapter, env, args, chdir)
        exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : status.to_i

        if exit_status != 0 && adapter.output_format != :exit_code
          raise Hecks::ShellAdapterError.new(
            "shell adapter :#{adapter.name} exited #{exit_status}: #{stderr.to_s.strip}",
            adapter: adapter.name, exit_status: exit_status, stderr: stderr
          )
        end

        Result.new(
          output: parse_output(adapter.output_format, stdout, exit_status),
          raw_stdout: stdout,
          stderr: stderr,
          exit_status: exit_status
        )
      end

      # Capture stdout/stderr/status with optional timeout wrapping.
      #
      # @return [Array(String, String, Process::Status)]
      def capture(adapter, env, args, chdir)
        # Open3.capture3 with unsetenv_others clears the parent env first,
        # then layers adapter.env on top. Stdin is always closed empty.
        opts = {
          chdir: chdir,
          stdin_data: "",
          unsetenv_others: true
        }
        return Open3.capture3(env, adapter.command, *args, **opts) unless adapter.timeout
        capture_with_timeout(adapter, env, args, chdir)
      end

      # Spawn with a timeout, actively killing the child (and its process
      # group) so the caller doesn't wait the full child duration just
      # because the dispatcher raised early.
      #
      # @return [Array(String, String, Process::Status)]
      def capture_with_timeout(adapter, env, args, chdir)
        stdin, stdout, stderr, wait_thr = Open3.popen3(
          env, adapter.command, *args,
          chdir: chdir,
          unsetenv_others: true,
          pgroup: true
        )
        stdin.close
        pid = wait_thr.pid
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + adapter.timeout.to_f

        until wait_thr.join(0.01)
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            begin
              Process.kill("-KILL", pid)
            rescue Errno::ESRCH, Errno::EPERM
              # Process already exited or pgroup kill refused
            end
            wait_thr.join
            stdout.close rescue nil
            stderr.close rescue nil
            raise Hecks::ShellAdapterTimeoutError.new(
              "shell adapter :#{adapter.name} exceeded #{adapter.timeout}s timeout",
              adapter: adapter.name, timeout: adapter.timeout
            )
          end
        end
        [stdout.read, stderr.read, wait_thr.value]
      ensure
        [stdin, stdout, stderr].each { |io| io.close if io && !io.closed? }
      end

      # Parse stdout by output_format. Exit-code format discards stdout
      # and returns the exit status as an Integer.
      #
      # @return [Object] format-specific output
      def parse_output(format, stdout, exit_status)
        case format
        when :text       then stdout
        when :lines      then stdout.to_s.each_line.map(&:chomp).reject(&:empty?)
        when :json       then JSON.parse(stdout.to_s)
        when :json_lines then stdout.to_s.each_line.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
        when :exit_code  then exit_status
        else raise ArgumentError, "unknown output_format: #{format.inspect}"
        end
      end
    end
  end
end
