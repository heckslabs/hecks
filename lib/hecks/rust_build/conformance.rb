# frozen_string_literal: true

require "json"
require "open3"
require_relative "../rust_build"
require_relative "native_build"

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

      # The refusal kinds are not compared for ad-hoc filter steps: C8.3
      # (docs/semantics/bluebook-semantics.md) is open (RuntimeError in Ruby, TypeMismatch in
      # Rust), and only the message is byte-exact.
      FILTER_VERB = "filter "

      module_function

      # @param argv [Array<String>] the domain, the script and optionally the artifact
      # @return [Integer] 0 when the result is printed or matches, 1 on a mismatch
      # @raise [Failure] when the artifact cannot be run
      def call(argv)
        require_relative "../../hecks"
        require_relative "../fuzzing"
        domain, script, other = argv
        raise Failure, USAGE unless domain && script

        ours = comparable(Hecks::Fuzzing::Replay.call(domain, JSON.parse(File.read(script)).fetch("steps")))
        return print_result(ours) unless other

        theirs = normalize(JSON.parse(artifact_output(domain, script, other)))
        report(domain, script, ours, theirs)
      end

      def print_result(result)
        puts JSON.pretty_generate(result)
        0
      end

      # @param result [Hash] `Fuzzing::Replay`'s answer
      # @return [Hash{String => Object}] the surface a Rust artifact must reproduce
      def comparable(result)
        surface = {
          "instances" => result[:instances].transform_values { |state| JSON.parse(JSON.generate(state)) },
          "events"    => result[:events].map { |event| event_surface(event) },
          "refusals"  => result[:refusals].map do |refusal|
            { "verb" => refusal[:verb], "error" => refusal[:error], "kind" => refusal[:kind]&.split("::")&.last }
          end
        }
        # `verb` and `ok` only, as `Hecks::Fuzzing::Differential` compares; omitted when none.
        dry_runs = result[:dry_runs].map { |dry| { "verb" => dry[:verb].to_s, "ok" => dry[:ok] } }
        surface["dry_runs"] = dry_runs unless dry_runs.empty?
        surface
      end

      def event_surface(event)
        { "name" => event[:name], "aggregate" => event[:aggregate], "id" => event[:id].to_s,
          "payload" => JSON.parse(JSON.generate(event[:payload])) }
      end

      # The artifact's JSON for the script: live from a binary, or read from a file.
      def artifact_output(domain, script, other)
        case other
        when "native" then run_binary(native_binary || missing_native!, script)
        when "build" then run_binary(built_binary(domain), script)
        when /\.wasm\z/
          raise Failure, "#{other}: no such file — run hecks build_wasm #{domain} first" unless File.exist?(other)

          run_process(["wasmtime", "run", other], File.read(script))
        when ->(path) { !path.end_with?(".json") && File.file?(path) && File.executable?(path) }
          # A pinned per-domain binary, as named by a sweep's `replay:` line.
          run_binary(other, script)
        else File.read(other)
        end
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

      # Strips what a Rust run carries that Ruby has no analog for: `emitted_*` snapshot flags
      # (ADR 0048) and the wall-clock `occurred_at` stamp two runs can never match.
      def normalize(theirs)
        if theirs["instances"].is_a?(Hash)
          theirs["instances"].each_value do |record|
            record.reject! { |key, _| key.start_with?("emitted_") } if record.is_a?(Hash)
          end
        end
        theirs["events"].each { |event| event.delete("occurred_at") if event.is_a?(Hash) } if theirs["events"].is_a?(Array)
        theirs
      end

      def report(domain, script, ours, theirs)
        [ours, theirs].each { |side| drop_filter_kinds(side) }
        mismatches = mismatches(ours, theirs)
        if mismatches.empty?
          puts "#{domain} / #{script}: matches."
          return 0
        end

        warn "#{domain} / #{script}: #{mismatches.size} mismatch(es)\n\n#{mismatches.join("\n\n")}"
        1
      end

      def drop_filter_kinds(side)
        return unless side["refusals"].is_a?(Array)

        side["refusals"].each { |r| r.delete("kind") if r.is_a?(Hash) && r["verb"].to_s.start_with?(FILTER_VERB) }
      end

      def mismatches(ours, theirs)
        found = %w[instances events refusals].filter_map do |key|
          next if ours[key] == theirs[key]

          "#{key}:\n  ruby:  #{ours[key].inspect}\n  other: #{theirs[key].inspect}"
        end
        their_dry_runs = Array(theirs["dry_runs"]).map { |dry| dry.slice("verb", "ok") }
        if (ours["dry_runs"] || []) != their_dry_runs
          found << "dry_runs:\n  ruby:  #{ours["dry_runs"].inspect}\n  other: #{their_dry_runs.inspect}"
        end
        found
      end
    end
  end
end
