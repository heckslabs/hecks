# frozen_string_literal: true

require "open3"

module Hecks
  module QualityControlCli
    class QaGeneratedDomains
      # Checking one candidate domain: written to disk, optionally built against Rust, then run in
      # its own child process.
      module Evaluation
        private

        # `--check DIR`: one domain in this process, one result line.
        def check_one
          result = Hecks::Fuzzing::GeneratedDomainCheck.run(
            @options[:check], seeds: @options[:seeds], steps: @options[:steps], adversarial: @options[:adversarial],
                              binary: @options[:binary], differ: conformance_differ, match: @options[:match],
                              shrink_budget: @options[:shrink_budget]
          )
          puts "#{RESULT_MARKER}#{JSON.generate(result)}"
          EXIT_OK
        end

        def conformance_differ
          return unless @options[:binary]

          require File.join(@root, "spec/support/rust_conformance_helpers")
          Class.new do
            include RustConformanceHelpers

            attr_reader :structural_skips

            def initialize
              @structural_skips = Set.new
            end
          end.new
        end

        def child_check(dir, binary: nil, match: nil, shrink_budget: 0)
          args = child_check_args(dir, binary, match, shrink_budget)
          output, status = Open3.capture2e(*Child.argv(@root, "qa_generated_domains", *args), chdir: @root)
          line = output.lines.reverse.find { |candidate| candidate.start_with?(RESULT_MARKER) }
          return JSON.parse(line.delete_prefix(RESULT_MARKER)) if line

          { "status" => "error",
            "error"  => "child exited #{status.exitstatus} with no result: #{output.lines.last(5).join.strip}" }
        end

        def child_check_args(dir, binary, match, shrink_budget)
          args = ["--check", dir, "--seeds", @options[:seeds].to_s, "--steps", @options[:steps].to_s,
                  "--adversarial", @options[:adversarial].to_s, "--shrink-budget", shrink_budget.to_s]
          args += ["--binary", binary] if binary
          args += ["--match", JSON.generate(match)] if match
          args
        end

        def build_rust(dir)
          project = Hecks::RustBuild.capture("project_rust", [File.expand_path(dir, @root)],
                                             env: { "HECKS_RUST_DIR" => @scratch })
          return [nil, rust_failure("rust_projection", "#{project.out}#{project.err}".lines.last(12).join)] unless project.ok?

          cargo_build
        end

        def cargo_build
          cargo, status = Open3.capture2e("cargo", "build", "--no-default-features", "--features",
                                          Generator::DIRECTORY, chdir: @scratch)
          return [nil, rust_failure("rust_build", cargo.lines.grep(/error/).first(12).join)] unless status.success?

          binary = File.join(@scratch, "target/debug/rust-#{Generator::DIRECTORY}")
          FileUtils.cp(File.join(@scratch, "target/debug/rust"), binary)
          [binary, nil]
        end

        def rust_failure(mode, detail) = { "mode" => mode, "detail" => detail }

        def sync_scratch!
          FileUtils.mkdir_p(@scratch)
          sources = %w[Cargo.toml Cargo.lock src].map { |entry| File.join(@root, "rust", entry) }
          system("rsync", "-a", "--delete", "--exclude", "target", *sources, "#{@scratch}/") or
            abort "rsync into #{@scratch} failed"
        end

        # Builds one candidate (when --rust) and runs a child check. A build failure is its own
        # result shape, so a rust_build finding shrinks by "does it still fail to build".
        def evaluate(blueprint, dir_root, match: nil, shrink_budget: 0)
          dir = Generator.write(blueprint, dir_root)
          binary = nil
          if @options[:rust]
            binary, failure = build_rust(dir)
            return rust_failure_result(failure, match, dir) if failure
            return { "status" => "clean" } if match && match["mode"].start_with?("rust_")
          end
          child_check(dir, binary: binary, match: match, shrink_budget: shrink_budget)
            .merge("binary" => binary, "dir" => dir)
        end

        def rust_failure_result(failure, match, dir)
          return { "status" => "clean" } unless match.nil? || match["mode"] == failure["mode"]

          { "status" => "found", "mode" => failure["mode"], "signature" => [failure["mode"]], "dir" => dir,
            "divergences" => [{ "field" => failure["mode"], "detail" => failure["detail"] }], "steps" => [] }
        end
      end
    end
  end
end
