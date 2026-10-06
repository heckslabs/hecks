# frozen_string_literal: true

require "json"
require "open3"
require_relative "../rust_build"
require_relative "native_build"
require_relative "conformance/surface"

module Hecks
  module RustBuild
    # The differential harness (ADR 0010): replays a corpus script through the Ruby interpreter
    # (`Fuzzing::Replay`) and prints or diffs the JSON surface a Rust artifact must reproduce.
    #
    # With no artifact it prints Ruby's result as JSON, which saved to a file becomes a pinned
    # expectation. The artifact is another artifact's JSON file, `native` (the workspace's
    # `target/{release,debug}/rust`), a `.wasm` path (run under `wasmtime`), an executable path,
    # or `build` (the domain's own Cargo feature, built and run); a live one gets the script on
    # stdin. `HECKS_RUST_DIR` names the workspace and `CARGO_TARGET_DIR` where its output went.
    module Conformance
      USAGE = "usage: hecks check_conformance <domain> <script.json> " \
              "[rust_output.json | native | build | path/to/binary | path/to/module.wasm]"

      module_function

      # @param argv [Array<String>] the domain, the script and optionally the artifact
      # @return [Integer] 0 when the result is printed or matches, 1 on a mismatch
      # @raise [Failure] when the artifact cannot be run
      def call(argv)
        require_relative "../../hecks"
        require_relative "../fuzzing"
        domain, script, other = argv
        raise Failure, USAGE unless domain && script

        ours = Surface.comparable(Hecks::Fuzzing::Replay.call(domain, JSON.parse(File.read(script)).fetch("steps")))
        return print_result(ours) unless other

        theirs = Surface.normalize(JSON.parse(artifact_output(domain, script, other)))
        report(domain, script, ours, theirs)
      end

      def print_result(result)
        puts JSON.pretty_generate(result)
        0
      end

      # The artifact's JSON for the script: live from a binary, or read from a file.
      def artifact_output(domain, script, other)
        case other
        when "native" then run_binary(native_binary || missing_native!, script)
        when "build" then run_binary(built_binary(domain), script)
        when /\.wasm\z/ then run_wasm(domain, script, other)
        when method(:pinned_binary?) then run_binary(other, script)
        else File.read(other)
        end
      end

      def run_wasm(domain, script, wasm)
        raise Failure, "#{wasm}: no such file — run hecks build_wasm #{domain} first" unless File.exist?(wasm)

        run_process(["wasmtime", "run", wasm], File.read(script))
      end

      # A pinned per-domain binary, as named by a sweep's `replay:` line.
      def pinned_binary?(path)
        !path.end_with?(".json") && File.file?(path) && File.executable?(path)
      end

      def run_binary(binary, script) = run_process([binary], File.read(script))

      def run_process(command, stdin_data)
        stdout, status = Open3.capture2(*command, stdin_data: stdin_data)
        raise Failure, "#{command.join(" ")} exited #{status.exitstatus}:\n#{stdout}" unless status.success?

        stdout
      end

      def target_dir = ENV.fetch("CARGO_TARGET_DIR", File.join(RustBuild.rust_dir, "target"))

      def native_binary
        %w[release debug].map { |profile| File.join(target_dir, profile, "rust") }.find { |path| File.executable?(path) }
      end

      def missing_native!
        raise Failure, "no native rust binary found under rust/target/{release,debug}/rust — run " \
                       "`cd rust && cargo build` first"
      end

      # Built on demand because `native` runs whichever domain the crate's default feature names.
      def built_binary(domain)
        feature = File.basename(domain.chomp("/"))
        NativeBuild.build_rust_for(feature, RustBuild.rust_dir) or
          raise Failure, "no `#{feature}` feature in rust/Cargo.toml — run hecks project_rust #{domain} first"
      end

      def report(domain, script, ours, theirs)
        [ours, theirs].each { |side| Surface.drop_filter_kinds(side) }
        mismatches = mismatches(ours, theirs)
        if mismatches.empty?
          puts "#{domain} / #{script}: matches."
          return 0
        end

        warn "#{domain} / #{script}: #{mismatches.size} mismatch(es)\n\n#{mismatches.join("\n\n")}"
        1
      end

      def mismatches(ours, theirs)
        found = %w[instances events refusals].filter_map do |key|
          next if ours[key] == theirs[key]

          "#{key}:\n  ruby:  #{ours[key].inspect}\n  other: #{theirs[key].inspect}"
        end
        dry = dry_run_mismatch(ours, theirs)
        found << dry if dry
        found
      end

      def dry_run_mismatch(ours, theirs)
        their_dry_runs = Array(theirs["dry_runs"]).map { |dry| dry.slice("verb", "ok") }
        return if (ours["dry_runs"] || []) == their_dry_runs

        "dry_runs:\n  ruby:  #{ours["dry_runs"].inspect}\n  other: #{their_dry_runs.inspect}"
      end
    end
  end
end
