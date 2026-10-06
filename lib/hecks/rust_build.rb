# frozen_string_literal: true

require "monitor"
require "tempfile"
require_relative "hecks/adapters/console_capture"

module Hecks
  # The tools that generate a domain's Rust source, compile it and check the build against the Ruby
  # engine, carried in the gem so a caller reaches them in this process.
  #
  # Each tool is a module with `call(argv) -> Integer`: it reads its arguments as a command line
  # would give them, prints its report to `$stdout` and its complaints to `$stderr`, reads
  # `ENV` for its settings, and answers an exit status. `run` and `capture` are the entry points:
  # they hand a tool the streams and environment it is asked to use for the length of one call,
  # and turn a refusal (`Failure`, `abort`, an unexpected error) into a status and a message. The
  # `hecks project_rust` family of verbs runs them through `run`.
  module RustBuild
    # The gem's root directory, where `lib/` and `rust/` live.
    ROOT = File.expand_path("../..", __dir__)

    # Raised by a tool to refuse, with the reason as the message.
    class Failure < StandardError; end

    # What one captured call did: `out` and `err` (what the tool printed) and its exit `status`.
    Result = Struct.new(:out, :err, :status) do
      # @return [Boolean] whether the tool succeeded
      def ok? = status.zero?
    end

    # Tool name to the file that defines it and the constant it defines.
    TOOLS = {
      "project_rust"          => ["rust_build/project_rust", :ProjectRust],
      "project_wasm"          => ["rust_build/wasm", :Wasm],
      "project_host"          => ["rust_build/host", :Host],
      "project_wasm_browser"  => ["rust_build/wasm_browser", :WasmBrowser],
      "rust_conformance"      => ["rust_build/conformance", :Conformance],
      "rust_conformance_fuzz" => ["rust_build/conformance_fuzz", :ConformanceFuzz],
      "rust_coverage"         => ["rust_build/coverage", :Coverage]
    }.freeze

    # The process-wide lock a call holds while it swaps `ENV`, `$stdout` and `$stderr`; the same
    # lock `ConsoleCapture` holds, so a build and a capture never interleave.
    LOCK = Hecks::Adapters::ConsoleCapture::LOCK
    private_constant :LOCK

    class << self
      # The workspace tools build in: `HECKS_RUST_DIR`, or the gem's own `rust/`.
      #
      # @return [String] the directory
      def rust_dir = ENV.fetch("HECKS_RUST_DIR", File.join(ROOT, "rust"))

      # Runs a tool with the given environment, writing to the given streams.
      #
      # The process's `ENV`, `$stdout` and `$stderr` are replaced for the length of the call, so
      # calls are serialized.
      #
      # @param tool [String] a key of `TOOLS`
      # @param argv [Array<String>] the tool's arguments
      # @param env [Hash{String => String, nil}] variables to set for the call (nil removes one)
      # @param out [IO] where the tool's stdout goes; must be a real IO (a file or the terminal)
      # @param err [IO] where the tool's stderr goes
      # @return [Integer] the exit status
      def run(tool, argv, env: {}, out: $stdout, err: $stderr)
        LOCK.synchronize do
          with_env(env) do
            with_streams(out, err) { finish(tool, argv) }
          end
        end
      end

      # Runs a program, its output going where the running tool's output goes.
      #
      # @param command [Array<String>] the program and its arguments
      # @param chdir [String, nil] the directory to run it in
      # @param env [Hash{String => String}] variables to set for it
      # @return [void]
      # @raise [Failure] when it cannot start or ends non-zero
      def command!(*command, chdir: nil, env: {})
        options = { out: $stdout, err: $stderr }
        options[:chdir] = chdir if chdir
        return if system(env, *command, **options)

        raise Failure, "`#{command.join(" ")}` failed#{" in #{chdir}" if chdir}"
      end

      # Runs a tool and holds what it printed.
      #
      # @param tool [String] a key of `TOOLS`
      # @param argv [Array<String>] the tool's arguments
      # @param env [Hash{String => String, nil}] variables to set for the call
      # @return [Result] what it printed, and how it ended
      def capture(tool, argv, env: {})
        Tempfile.create("rust_build_out") do |out|
          Tempfile.create("rust_build_err") do |err|
            status = run(tool, argv, env: env, out: out, err: err)
            [out, err].each(&:flush)
            Result.new(File.read(out.path), File.read(err.path), status)
          end
        end
      end

      # Sets variables for the block and puts them back after, for a nested tool call.
      #
      # @param env [Hash{String => String, nil}] variables to set (nil removes one)
      # @yield the work to do under those variables
      # @return [Object] the block's value
      def with_env(env)
        LOCK.synchronize do
          saved = env.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
          begin
            env.each { |key, value| ENV[key] = value }
            yield
          ensure
            saved.each { |key, value| ENV[key] = value }
          end
        end
      end

      private

      def with_streams(out, err)
        saved = [$stdout, $stderr]
        $stdout = out
        $stderr = err
        yield
      ensure
        $stdout, $stderr = saved
      end

      def finish(tool, argv)
        file, constant = TOOLS.fetch(tool)
        require_relative file
        RustBuild.const_get(constant).call(argv)
      rescue Failure => e
        warn e.message
        1
      rescue SystemExit => e
        e.status
      rescue StandardError, ScriptError => e
        warn "#{tool}: #{e.class}: #{e.message}"
        1
      end
    end
  end
end
