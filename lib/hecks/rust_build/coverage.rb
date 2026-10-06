# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../rust_build"
require_relative "coverage_parts/expected"
require_relative "coverage_parts/printer"

module Hecks
  module RustBuild
    # Reports whether each construct in a domain's IR has a real, routed implementation under
    # `<workspace>/src/generated/<domain>` (ADR 0054a).
    #
    #   Coverage.call([domain, "--codegen=ruby|rust"])
    #   Coverage.call(["--check-allowlist"])
    #
    # Ground truth is the generated module's `ir.json` and its `manifest.json`; a construct in the
    # IR that the manifest omits is a synthetic `unaccounted` finding. The exit status is 1 when a
    # gap remains that the allowlist does not excuse.
    module Coverage
      USAGE = "usage: hecks rust_coverage <generated-module-name> [--codegen=ruby|rust]  " \
              "(e.g. pizzas, banking, governance, identity)\n       hecks rust_coverage --check-allowlist"

      # Deliberate, documented gaps only, matched by kind, gap class and construct (never a regex
      # over `reason` prose). The list only shrinks: `--check-allowlist` fails once a rule excuses
      # no gap anywhere.
      ALLOWLIST = [].freeze

      module_function

      # @param argv [Array<String>] the generated module's name and optional `--codegen=` flag,
      #   or `--check-allowlist`
      # @return [Integer] 0 when nothing is a gap, 1 otherwise
      # @raise [Failure] when the module, its `ir.json` or its manifest is missing
      def call(argv)
        flags, positional = argv.partition { |arg| arg.start_with?("--codegen") }
        codegen = flags.empty? ? "ruby" : flags.last.delete_prefix("--codegen=")
        raise Failure, "--codegen must be `ruby` or `rust` (got #{flags.last.inspect})" unless %w[ruby rust].include?(codegen)

        target = positional.first or raise Failure, USAGE
        return check_allowlist if target == "--check-allowlist"

        report(target, codegen)
      end

      def rust_dir = RustBuild.rust_dir

      def generated_root = File.join(rust_dir, "src/generated")

      # Parses a generated module's `ir.json` and `manifest.json`, adding a synthetic `unaccounted`
      # finding for any IR construct the manifest omits.
      def coverage_findings(mod_dir)
        ir = read_json(File.join(mod_dir, "ir.json"),
                       "this generated tree predates ir.json (hecks project_rust writes it now); " \
                       "re-run hecks project_rust for this domain")
        manifest = read_json(File.join(mod_dir, "manifest.json"),
                             "re-run hecks project_rust for this domain to write it")
        [ir, manifest + unaccounted_findings(ir, manifest)]
      end

      def read_json(path, hint)
        File.exist?(path) or raise Failure, "#{path}: missing — #{hint}"
        JSON.parse(File.read(path), symbolize_names: true)
      end

      def allowlist_rule_matches?(rule, finding)
        rule[:kind] == finding[:kind].to_s &&
          rule[:gap_class] == finding[:gap_class].to_s &&
          rule[:construct] == finding[:construct].to_s
      end

      def allowlisted(finding) = ALLOWLIST.find { |rule| allowlist_rule_matches?(rule, finding) }

      # A synthetic finding for each expected construct with no manifest entry at all: a gap in
      # the manifest writer itself.
      def unaccounted_findings(payload, manifest)
        ids = manifest.group_by { |entry| entry[:kind].to_sym }.transform_values { |entries| entries.to_set { |e| e[:id] } }
        Expected.from_ir(payload).reject { |kind, id| ids.fetch(kind, Set.new).include?(id) }
                .map { |kind, id| unaccounted(kind, id) }
      end

      def unaccounted(kind, id)
        { kind: kind.to_s, id: id, generated: false, gap_class: "unaccounted", construct: "unaccounted",
          reason: "expected per ir.json, but manifest.json has NO entry for it at all — not even a " \
                  "recorded skip; the generator's own accounting missed this construct entirely" }
      end

      # A real functional gap: not generated, or generated but unrouted.
      def functional_gap?(finding) = finding[:generated] == false || finding[:routed] == false

      # Every rule must still excuse a real gap somewhere under `src/generated/`.
      def check_allowlist
        gaps = Dir.glob(File.join(generated_root, "*/ir.json")).flat_map { |ir_path| gaps_in(File.dirname(ir_path)) }
        stale = ALLOWLIST.reject { |rule| gaps.any? { |finding| allowlist_rule_matches?(rule, finding) } }
        return report_stale(stale) unless stale.empty?

        puts "hecks rust_coverage --check-allowlist: all #{ALLOWLIST.size} rules still excuse a real gap"
        0
      end

      def gaps_in(mod_dir) = coverage_findings(mod_dir)[1].select { |finding| functional_gap?(finding) }

      def report_stale(stale)
        stale.each do |rule|
          warn "STALE ALLOWLIST RULE: #{rule.slice(:kind, :gap_class, :construct)} matches no gap in any generated " \
               "module — the gap it excused is gone; delete the rule"
        end
        1
      end

      def report(domain, codegen)
        mod_dir = File.join(generated_root, domain)
        Dir.exist?(mod_dir) or raise Failure, "#{mod_dir}: no such generated module — run hecks project_rust first, " \
                                              "or check rust/src/generated/ for the actual directory name"
        return print_report(domain, mod_dir) unless codegen == "rust"

        Dir.mktmpdir("rust-coverage-codegen-") do |scratch|
          print_report(domain, regenerated(mod_dir, domain, scratch))
        end
      end

      # Regenerates the domain's manifest through `hecks-codegen` into a scratch directory. `cargo
      # run` rather than a fixed target path, so `CARGO_TARGET_DIR` and rust-toolchain.toml apply.
      def regenerated(mod_dir, domain, scratch)
        ir_path = File.join(mod_dir, "ir.json")
        File.exist?(File.join(mod_dir, "manifest.json")) or raise Failure, "#{mod_dir}: no committed manifest.json — " \
                                                                           "re-run hecks project_rust for this domain to write it"
        out_dir = File.join(scratch, domain)
        output, status = Open3.capture2e("cargo", "run", "--quiet", "--", "domain", ir_path, domain, domain, out_dir,
                                         chdir: File.join(rust_dir, "codegen"))
        status.success? or raise Failure, "hecks-codegen domain failed for #{domain}:\n#{output}"
        # `hecks-codegen domain` writes no ir.json sidecar; the cross-check reads the committed IR
        # the generator was just handed.
        FileUtils.cp(ir_path, File.join(out_dir, "ir.json"))
        out_dir
      end

      def print_report(domain, mod_dir)
        ir, findings = coverage_findings(mod_dir)
        Printer.report(domain, ir.fetch(:name), findings, method(:allowlisted))
      end
    end
  end
end
