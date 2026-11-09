# frozen_string_literal: true

require "json"
require "open3"
require_relative "../rust_build"
require_relative "native_build"
require_relative "conformance/surface"
require_relative "kernel_input"

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

      # A compiled wasm module's path.
      WASM_MODULE = /\.wasm\z/

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
        when "native" then run_binary(native_binary || missing_native!, kernel_input(domain, script))
        when "build" then run_binary(built_binary(domain), kernel_input(domain, script))
        when WASM_MODULE then run_wasm(domain, script, other)
        when method(:pinned_binary?) then run_binary(other, kernel_input(domain, script))
        else File.read(other)
        end
      end

      # The stdin a compiled artifact reads: the script's steps with the domain's `defaults`,
      # `needs` and `query_needs` tables beside them, as every other conformance caller sends
      # them (`KernelInput`). Without the tables the kernel never answers a fact the declaration
      # `needs`, and a Ruby-filled argument refuses on the Rust side.
      def kernel_input(domain, script)
        input = JSON.parse(File.read(script))
        KernelInput.tables_for(domain).each { |name, table| input[name] = table unless table.empty? }
        JSON.generate(input)
      end

      def run_wasm(domain, script, wasm)
        raise Failure, "#{wasm}: no such file — run hecks build_wasm #{domain} first" unless File.exist?(wasm)

        run_process(["wasmtime", "run", wasm], kernel_input(domain, script))
      end

      # A pinned per-domain binary, as named by a sweep's `replay:` line.
      def pinned_binary?(path)
        !path.end_with?(".json") && File.file?(path) && File.executable?(path)
      end

      def run_binary(binary, stdin) = run_process([binary], stdin)

      def run_process(command, stdin_data)
        stdout, status = Open3.capture2(*command, stdin_data: stdin_data)
        raise Failure, "#{command.join(" ")} exited #{status.exitstatus}:\n#{stdout}" unless status.success?

        stdout
      end

      # Where a build of the workspace puts its binaries: the directory named by hand, else the
      # worktree's own slot below the shared target (where `NativeBuild` builds), else the
      # workspace's own `target/`; a directory named by hand is taken from the workspace, as Cargo
      # takes it.
      def target_dirs
        rust_dir = RustBuild.rust_dir
        [NativeBuild.target_dir(rust_dir), File.join(rust_dir, "target")].uniq
      end

      def native_binary
        paths = target_dirs.product(%w[release debug]).map { |dir, profile| File.join(dir, profile, "rust") }
        paths.find { |path| File.executable?(path) }
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
        found = %w[instances events refusals cross_domain].filter_map do |key|
          next if ours[key] == theirs[key]

          "#{key}:\n  ruby:  #{ours[key].inspect}\n  other: #{theirs[key].inspect}"
        end
        dry = dry_run_mismatch(ours, theirs)
        found << dry if dry
        validated = validation_mismatch(ours, theirs)
        found << validated if validated
        found
      end

      # A Rust dry run on the same surface as Ruby's: `verb`, `ok`, and each refusal's kind, stage,
      # attribute, path and rule where the stage is one both engines list in full.
      def their_dry_run(dry)
        reasons = Array(dry["refusals"]).map do |refusal|
          refusal.values_at("kind", "stage", "attribute", "path", "rule", "refusal")
        end
        dry.slice("verb", "ok").merge(Surface.collected_refusals(reasons))
      end

      # A `validate` step's answer, whole: the same refusals in the same order from both engines.
      def validation_mismatch(ours, theirs)
        mine = ours["validations"] || []
        return if mine == (theirs["validations"] || [])

        "validations:\n  ruby:  #{mine.inspect}\n  other: #{theirs["validations"].inspect}"
      end

      def dry_run_mismatch(ours, theirs)
        their_dry_runs = Array(theirs["dry_runs"]).map { |dry| their_dry_run(dry) }
        return if (ours["dry_runs"] || []) == their_dry_runs

        "dry_runs:\n  ruby:  #{ours["dry_runs"].inspect}\n  other: #{their_dry_runs.inspect}"
      end
    end
  end
end
