# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "../../../hecks"
require "hecks/rust_build"
require_relative "../../fuzzing"
require_relative "../../fuzzing/domain_generator"
require_relative "../../fuzzing/generated_domain_check"
require_relative "child"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.check_generated_domains`: generates domains
    # nobody wrote and checks them the way the rotation does (`USAGE` lists the forms: generate,
    # `--blueprint`, `--source` and `--promote`).
    #
    # Exit codes: 0 every valid domain clean; 2 at least one finding; 1 operational error.
    #
    # Every generated domain is named `QaGenerated`, so each is checked in its own child process
    # (`--check <dir>`, prints one `QA_GENERATED_RESULT <json>` line). Findings are shrunk twice:
    # the domain, then the steps. `--rust` builds a scratch crate under `tmp/qa-generated/rust`.
    # `--source` adopts a bluebook written elsewhere; a `HYPOTHESIS.md` beside it rides into
    # `NOTES.md`. It never touches the QA ledger; a domain that does not boot is `invalid`, never a
    # finding.
    class QaGeneratedDomains
      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_FOUND = 2
      RESULT_MARKER = "QA_GENERATED_RESULT "

      USAGE = "usage: hecks quality_control check_generated_domains [--domains N] [--start SEED] " \
              "[--forms a,b] [--seeds K] [--steps M] [--adversarial F] [--rust] [--shrink-budget B] " \
              "[--domain-shrink-budget D]\n       " \
              "hecks quality_control check_generated_domains --source <file.bluebook> [--source …] [--rust] …\n       " \
              "hecks quality_control check_generated_domains --promote <finding-dir> --name <stress_domain_name>"

      Generator = Hecks::Fuzzing::DomainGenerator

      # Generates, checks and reports.
      #
      # @param argv [Array<String>] the flags in the usage line
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_GENERATED_DOMAINS_PER_TICK` overrides the count of
      #   `--from-dials`
      # @return [Integer] 0 clean, 2 a finding, 1 an operational error
      # @raise [SystemExit] on a bad argument or a missing file
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_GENERATED_DOMAINS_PER_TICK` overrides the count of
      #   `--from-dials`
      def initialize(root:, env: ENV)
        @root = root
        @env = env
      end

      # @param argv [Array<String>] the flags in the usage line
      # @return [Integer] the exit status
      # @raise [SystemExit] on a bad argument or a missing file
      def call(argv)
        @options = parse(argv.dup)
        return EXIT_OK if @options == :help
        return check_one if @options[:check]
        return promote if @options[:promote]
        return EXIT_OK if @options[:from_dials] && !dials_on?

        run
      end

      # Each flag that takes a value: the option it sets and how the value is read.
      VALUE_FLAGS = {
        "--domains" => [:domains, ->(v) { Integer(v) }], "--start" => [:start, ->(v) { Integer(v) }],
        "--forms" => [:forms, ->(v) { v.split(",") }], "--seeds" => [:seeds, ->(v) { Integer(v) }],
        "--steps" => [:steps, ->(v) { Integer(v) }], "--adversarial" => [:adversarial, ->(v) { Float(v) }],
        "--shrink-budget" => [:shrink_budget, ->(v) { Integer(v) }],
        "--domain-shrink-budget" => [:domain_shrink_budget, ->(v) { Integer(v) }],
        "--check" => [:check, :itself.to_proc], "--binary" => [:binary, :itself.to_proc],
        "--match" => [:match, ->(v) { JSON.parse(v) }], "--promote" => [:promote, :itself.to_proc],
        "--name" => [:name, :itself.to_proc], "--blueprint" => [:blueprint, :itself.to_proc]
      }.freeze

      # Each flag that stands alone, and the option it turns on.
      SWITCH_FLAGS = { "--rust" => :rust, "--from-dials" => :from_dials }.freeze

      private

      def parse(argv)
        options = { domains: 3, start: nil, forms: nil, seeds: 5, steps: 25, adversarial: 0.3, rust: false,
                    shrink_budget: 200, domain_shrink_budget: 40, check: nil, binary: nil, match: nil,
                    promote: nil, name: nil, sources: [] }
        until argv.empty?
          arg = argv.shift
          if %w[-h --help].include?(arg)
            puts USAGE
            return :help
          end
          parse_flag(options, arg, argv)
        end
        options
      end

      def parse_flag(options, arg, argv)
        if VALUE_FLAGS.key?(arg)
          key, reader = VALUE_FLAGS.fetch(arg)
          options[key] = reader.call(argv.shift)
        elsif SWITCH_FLAGS.key?(arg)
          options[SWITCH_FLAGS.fetch(arg)] = true
        elsif arg == "--source"
          options[:sources] << argv.shift
        else
          abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
        end
      end

      # `--check DIR`: one domain in this process, one result line.
      def check_one
        differ = nil
        if @options[:binary]
          require File.join(@root, "spec/support/rust_conformance_helpers")
          differ = Class.new do
            include RustConformanceHelpers

            attr_reader :structural_skips

            def initialize
              @structural_skips = Set.new
            end
          end.new
        end
        result = Hecks::Fuzzing::GeneratedDomainCheck.run(
          @options[:check], seeds: @options[:seeds], steps: @options[:steps], adversarial: @options[:adversarial],
                            binary: @options[:binary], differ: differ, match: @options[:match],
                            shrink_budget: @options[:shrink_budget]
        )
        puts "#{RESULT_MARKER}#{JSON.generate(result)}"
        EXIT_OK
      end

      def camelize(name) = name.split("_").map(&:capitalize).join

      def promote
        name = @options[:name] or abort "#{USAGE}\n--promote needs --name"
        unless name.match?(/\A[a-z][a-z0-9_]*\z/)
          abort "--name must be a lowercase identifier (it becomes a Rust module and Cargo feature)"
        end

        source = File.join(@options[:promote], Generator::DIRECTORY, "bluebook", "#{Generator::DIRECTORY}.bluebook")
        abort "no generated domain at #{source}" unless File.exist?(source)
        target = File.join(@root, "qa/stress_domains", name)
        abort "#{target} already exists — pick another --name" if File.exist?(target)

        FileUtils.mkdir_p(File.join(target, "bluebook"))
        File.write(File.join(target, "bluebook", "#{name}.bluebook"),
                   File.read(source).gsub(Generator::DOMAIN_NAME, camelize(name)))
        File.write(File.join(target, "NOTES.md"), notes_for(name))
        puts "promoted: qa/stress_domains/#{name}"
        puts "next:"
        puts "  hecks quality_control judge_novelty qa/stress_domains/#{name}"
        puts "  hecks project_rust qa/stress_domains/#{name}  # when the finding needs the Rust comparison"
        # `hecks quality_control target.seed` derives targets from
        # `Hecks::Corpus.rotation_targets`, so a hand-typed `target.identify` line is not printed:
        # nobody ran it and the domain never
        # entered the rotation.
        puts "  hecks quality_control target.seed   # idempotent; picks this domain up from the corpus"
        EXIT_OK
      end

      def notes_for(name)
        blueprint = File.join(@options[:promote], "blueprint.json")
        finding = File.join(@options[:promote], "finding.json")
        recorded = File.exist?(blueprint) ? JSON.parse(File.read(blueprint)) : nil
        hypothesis = recorded&.dig("hypothesis")
        <<~NOTES
          # #{name}

          Promoted from a `hecks quality_control check_generated_domains` finding — #{recorded&.key?("source") ? "written by `hecks quality_control mine_combinations`' agent" : "generated"}, not
          hand-written. The bluebook is the minimal form of the domain that
          surprised; `QaGenerated` was renamed to `#{camelize(name)}` and nothing
          else changed.
          #{"\n## Hypothesis\n\n#{hypothesis.strip}\n" if hypothesis}
          ## Blueprint

          ```json
          #{recorded ? JSON.pretty_generate(recorded.except("source", "hypothesis")) : "(not recorded)"}
          ```

          ## Finding

          ```json
          #{File.exist?(finding) ? File.read(finding).strip : "(not recorded)"}
          ```
        NOTES
      end

      def dial(name, fallback)
        return fallback unless defined?(::QualityControlDials) && ::QualityControlDials.const_defined?(name)

        ::QualityControlDials.const_get(name)
      end

      # `--from-dials` is how `hecks quality_control sweep.tick` runs this. The dials come from the
      # text of the bluebook before `Hecks.bluebook`, so the ledger's Postgres is not needed.
      # `QA_GENERATED_DOMAINS_PER_TICK` overrides the count for one run.
      #
      # @return [Boolean] false when the dials turn the step off, true once they are applied
      def dials_on?
        dials_path = File.join(@root, "lib/hecks/quality_control/quality_control.bluebook")
        eval(File.read(dials_path).split(/^Hecks\.bluebook/).first, TOPLEVEL_BINDING, dials_path)
        # rubocop:enable Security/Eval
        per_tick = Integer(@env.fetch("QA_GENERATED_DOMAINS_PER_TICK", dial(:GENERATED_DOMAINS_PER_TICK, 0)))
        if per_tick.zero?
          puts "generated domains: off (QualityControlDials::GENERATED_DOMAINS_PER_TICK is 0)"
          return false
        end
        @options.merge!(domains: per_tick, rust: dial(:GENERATED_DOMAINS_RUST, false),
                        seeds: dial(:GENERATED_DOMAIN_SEEDS, 5), adversarial: dial(:ADVERSARIAL_FRACTION, 0.3).to_f)
        true
      end

      def child_check(dir, binary: nil, match: nil, shrink_budget: 0)
        args = ["--check", dir, "--seeds", @options[:seeds].to_s, "--steps", @options[:steps].to_s,
                "--adversarial", @options[:adversarial].to_s, "--shrink-budget", shrink_budget.to_s]
        args += ["--binary", binary] if binary
        args += ["--match", JSON.generate(match)] if match
        output, status = Open3.capture2e(*Child.argv(@root, "qa_generated_domains", *args), chdir: @root)
        line = output.lines.reverse.find { |candidate| candidate.start_with?(RESULT_MARKER) }
        return JSON.parse(line.delete_prefix(RESULT_MARKER)) if line

        { "status" => "error",
          "error"  => "child exited #{status.exitstatus} with no result: #{output.lines.last(5).join.strip}" }
      end

      def build_rust(dir)
        project = Hecks::RustBuild.capture("project_rust", [File.expand_path(dir, @root)],
                                           env: { "HECKS_RUST_DIR" => @scratch })
        unless project.ok?
          return [nil, { "mode" => "rust_projection", "detail" => "#{project.out}#{project.err}".lines.last(12).join }]
        end

        cargo, status = Open3.capture2e("cargo", "build", "--no-default-features", "--features",
                                        Generator::DIRECTORY, chdir: @scratch)
        return [nil, { "mode" => "rust_build", "detail" => cargo.lines.grep(/error/).first(12).join }] unless status.success?

        binary = File.join(@scratch, "target/debug/rust-#{Generator::DIRECTORY}")
        FileUtils.cp(File.join(@scratch, "target/debug/rust"), binary)
        [binary, nil]
      end

      def sync_scratch!
        FileUtils.mkdir_p(@scratch)
        sources = %w[Cargo.toml Cargo.lock src].map { |entry| File.join(@root, "rust", entry) }
        system("rsync", "-a", "--delete", "--exclude", "target", *sources, "#{@scratch}/") or
          abort "rsync into #{@scratch} failed"
      end

      # Builds one candidate (when --rust) and runs a child check. A build failure is its own result
      # shape, so a rust_build finding shrinks by "does it still fail to build".
      def evaluate(blueprint, dir_root, match: nil, shrink_budget: 0)
        dir = Generator.write(blueprint, dir_root)
        binary = nil
        if @options[:rust]
          binary, failure = build_rust(dir)
          if failure
            return { "status" => "clean" } unless match.nil? || match["mode"] == failure["mode"]

            return { "status" => "found", "mode" => failure["mode"], "signature" => [failure["mode"]], "dir" => dir,
                     "divergences" => [{ "field" => failure["mode"], "detail" => failure["detail"] }], "steps" => [] }
          end
          return { "status" => "clean" } if match && match["mode"].start_with?("rust_")
        end
        child_check(dir, binary: binary, match: match, shrink_budget: shrink_budget)
          .merge("binary" => binary, "dir" => dir)
      end

      def shrink_domain(blueprint, found, root)
        match = { "mode" => found["mode"], "signature" => found["signature"] }
        current = blueprint
        attempts = 0
        loop do
          accepted = false
          Generator.shrink_candidates(current).each do |candidate|
            break if attempts >= @options[:domain_shrink_budget]

            attempts += 1
            next unless evaluate(candidate, File.join(root, "candidate"), match: match)["status"] == "found"

            current = candidate
            accepted = true
            break
          end
          break unless accepted && attempts < @options[:domain_shrink_budget]
        end
        [current, attempts]
      end

      def relative(path) = path.delete_prefix("#{@root}/")

      def print_finding_header(report)
        puts
        puts "=" * 72
        puts "GENERATED DOMAIN FOUND SOMETHING — domain seed #{report[:seed]}, forms #{report[:forms].join(" + ")}"
        puts "=" * 72
        puts "domain:      #{relative(report[:dir])}"
        puts "             shrunk from #{report[:size_before]} to #{report[:size_after]} removable element(s) " \
             "in #{report[:domain_attempts]} candidate check(s)"
        puts "blueprint:   #{relative(File.join(report[:root], "blueprint.json"))}"
      end

      def print_finding(report)
        found = report[:final]
        options = report[:options]
        print_finding_header(report)
        puts "mode:        #{found["mode"]}"
        puts "signature:   #{found["signature"].join(", ")}"
        if found["seed"]
          puts "sequence:    seed #{found["seed"]} of --seeds #{options[:seeds]}, #{options[:steps]} steps, " \
               "adversarial #{options[:adversarial]}"
        end
        print_shrunk(report, found["steps"], found["shrunk_steps"])
        puts "promote:     hecks quality_control check_generated_domains --promote " \
             "#{relative(report[:root])} --name <stress_domain_name>"
        puts
        found["divergences"].each do |divergence|
          puts "-- #{divergence["field"]} --"
          divergence.except("field").each do |key, value|
            puts "#{key}: #{value.is_a?(String) ? value : JSON.generate(value)}"
          end
          puts
        end
      end

      def print_shrunk(report, steps, shrunk)
        return unless shrunk

        puts "shrunk:      #{steps.size} -> #{shrunk.size} step(s) — #{relative(report[:steps_file])}"
        replay = if report[:binary]
                   "hecks check_conformance #{report[:dir]} script=#{report[:steps_file]} " \
                     "artifact=#{report[:binary]}"
                 else
                   "hecks run #{report[:dir]} #{report[:steps_file]}"
                 end
        puts "replay:      #{replay}"
        shrunk.each_with_index do |step, index|
          kind = %w[verb query dry_run].find { |key| step.key?(key) }
          puts "  #{index}: #{"#{kind} " unless kind == "verb"}#{step[kind]}  args: #{JSON.generate(step["args"])}"
        end
      end

      def record_finding(blueprint, result, root)
        minimal, attempts = shrink_domain(blueprint, result, root)
        final_root = File.join(root, "minimal")
        match = { "mode" => result["mode"], "signature" => result["signature"] }
        final = evaluate(minimal, final_root, match: match, shrink_budget: @options[:shrink_budget])
        unless final["status"] == "found"
          minimal = blueprint
          final = evaluate(blueprint, final_root, shrink_budget: @options[:shrink_budget])
        end
        File.write(File.join(final_root, "finding.json"), JSON.pretty_generate(final.except("dir", "binary")))
        steps_file = File.join(final_root, "shrunk_steps.json")
        note = "hecks quality_control check_generated_domains finding"
        File.write(steps_file, JSON.pretty_generate(name: "qa_generated-shrunk", note: note,
                                                    steps: final.fetch("shrunk_steps") { final.fetch("steps", []) }))
        { forms: blueprint["forms"], root: final_root, dir: final["dir"], binary: final["binary"], final: final,
          options: @options, steps_file: steps_file, domain_attempts: attempts,
          size_before: Generator.removals(blueprint).size, size_after: Generator.removals(minimal).size }
      end

      def blueprints(start)
        if @options[:blueprint]
          saved = JSON.parse(File.read(@options[:blueprint]))
          { saved.fetch("seed", start) => saved }
        elsif @options[:sources].any?
          @options[:sources].each_with_index.to_h { |file, index| [start + index, source_blueprint(file, start + index)] }
        else
          (start...(start + @options[:domains])).to_h do |seed|
            [seed, Generator.generate(seed: seed, forms: @options[:forms])]
          end
        end
      end

      def source_blueprint(file, seed)
        abort "no bluebook at #{file}" unless File.file?(file)

        hypothesis = File.join(File.dirname(file), "HYPOTHESIS.md")
        { "seed" => seed, "forms" => ["source:#{File.basename(File.dirname(file))}"],
          "origin" => File.expand_path(file), "source" => File.read(file),
          "hypothesis" => (File.read(hypothesis) if File.exist?(hypothesis)),
          "aggregates" => [], "policies" => [] }.compact
      end

      def run
        start = @options[:start] || (Time.now.to_i % 1_000_000)
        # `-<pid>`: two runs started in the same second must not share domain directories.
        run_dir = File.join(@root, "tmp/qa-generated/run-#{start}-#{Process.pid}")
        @scratch = File.join(@root, "tmp/qa-generated/rust")
        @options[:domains] = @options[:sources].size if @options[:sources].any?
        sync_scratch! if @options[:rust]
        puts "generated domains: #{@options[:domains]} starting at seed #{start}; #{@options[:seeds]} seed(s) x " \
             "#{@options[:steps]} steps each, adversarial #{@options[:adversarial]}" \
             "#{", against Rust" if @options[:rust]} — #{relative(run_dir)}"

        counts = Hash.new(0)
        findings = []
        # `--blueprint FILE` re-checks one saved blueprint through the same check/shrink/report
        # path.
        blueprints(start).each do |domain_seed, blueprint|
          check_blueprint(domain_seed, blueprint, run_dir, counts, findings)
        end
        report(counts, findings)
      end

      def check_blueprint(domain_seed, blueprint, run_dir, counts, findings)
        root = File.join(run_dir, domain_seed.to_s)
        result = evaluate(blueprint, root)
        label = "domain #{domain_seed} [#{blueprint["forms"].join("+")}]"
        label += " #{blueprint["aggregates"].size} aggregate(s)" unless blueprint["source"]

        case result["status"]
        when "clean"
          counts[:clean] += 1
          puts "  #{label}: clean (#{result["seeds_run"]} seed(s))"
        when "invalid", "error"
          counts[result["status"].to_sym] += 1
          puts "  #{label}: #{result["status"].upcase} — #{result["error"]}"
        else
          counts[:found] += 1
          puts "  #{label}: FOUND SOMETHING (#{result["mode"]}: #{result["signature"].join(", ")}) — " \
               "shrinking the domain…"
          findings << record_finding(blueprint, result, root).merge(seed: domain_seed)
        end
      end

      def report(counts, findings)
        puts
        puts "generated domains: #{counts[:clean]} clean, #{counts[:found]} found something, " \
             "#{counts[:invalid]} invalid, #{counts[:error]} errored"
        findings.each { |finding| print_finding(finding) }

        if findings.any? then EXIT_FOUND
        elsif counts[:clean].zero? then EXIT_ERROR
        else EXIT_OK
        end
      end
    end
  end
end
