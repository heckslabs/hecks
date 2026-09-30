# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../rust_build"

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
      USAGE = "usage: bin/rust_coverage <generated-module-name> [--codegen=ruby|rust]  " \
              "(e.g. pizzas, banking, governance, identity)\n       bin/rust_coverage --check-allowlist"

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

      # Entity-scoped query ids at any depth (`Domain::Aggregate.Entity.Query`); mirrors the
      # generator's own entity query entries.
      def entity_query_ids(owner_id, entities)
        entities.flat_map do |entity|
          entity_id = "#{owner_id}.#{entity.fetch(:name)}"
          entity.fetch(:queries, []).map { |q| "#{entity_id}.#{q.fetch(:name)}" } +
            entity_query_ids(entity_id, entity.fetch(:entities, []))
        end
      end

      # The [kind, id] pairs the IR implies, independent of the manifest.
      def expected_from_ir(payload)
        domain_name = payload.fetch(:name)
        expected = payload.fetch(:aggregates).flat_map { |aggregate| aggregate_constructs(domain_name, aggregate) }
        payload.fetch(:read_models).each { |rm| expected << [:read_model, "#{domain_name}::#{rm.fetch(:name)}"] }
        payload.fetch(:policies).each { |p| expected << [:policy, "#{domain_name}::#{p.fetch(:name)}"] }
        payload.fetch(:process_managers).each { |pm| expected << [:process_manager, "#{domain_name}::#{pm.fetch(:name)}"] }
        # An `ir.json` from before the `lineage` key existed has none: nothing to expect.
        payload.fetch(:lineage, {}).fetch(:capable_aggregates, []).each do |aggregate|
          expected << [:lineage_aggregate, "#{domain_name}::#{aggregate.fetch(:name)}"]
        end
        expected
      end

      def aggregate_constructs(domain_name, aggregate)
        id = "#{domain_name}::#{aggregate.fetch(:name)}"
        found = [[:aggregate, id]]
        aggregate.fetch(:commands).each { |c| found << [:command, "#{id}.#{c.fetch(:name)}"] }
        aggregate.fetch(:queries).each { |q| found << [:query, "#{id}.#{q.fetch(:name)}"] }
        entity_query_ids(id, aggregate.fetch(:entities)).each { |query_id| found << [:query, query_id] }
        aggregate.fetch(:entities).each do |entity|
          entity_id = "#{id}.#{entity.fetch(:name)}"
          found << [:entity, entity_id]
          entity.fetch(:commands).each { |c| found << [:entity_command, "#{entity_id}.#{c.fetch(:name)}"] }
        end
        aggregate.fetch(:ports).each do |port|
          port.fetch(:operations).each { |op| found << [:port_operation, "#{id}.#{port.fetch(:name)}.#{op.fetch(:name)}"] }
        end
        found
      end

      # Parses a generated module's `ir.json` and `manifest.json`, adding a synthetic `unaccounted`
      # finding for any IR construct the manifest omits.
      def coverage_findings(mod_dir)
        ir_path = File.join(mod_dir, "ir.json")
        File.exist?(ir_path) or raise Failure, "#{ir_path}: missing — this generated tree predates ir.json " \
                                               "(bin/project_rust writes it now); re-run bin/project_rust for this domain"
        ir = JSON.parse(File.read(ir_path), symbolize_names: true)
        manifest_path = File.join(mod_dir, "manifest.json")
        File.exist?(manifest_path) or raise Failure, "#{manifest_path}: missing — re-run bin/project_rust for this " \
                                                     "domain to write it"
        manifest = JSON.parse(File.read(manifest_path), symbolize_names: true)
        [ir, manifest + unaccounted_findings(ir, manifest)]
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
        ids = Hash.new { |hash, kind| hash[kind] = Set.new }
        manifest.each { |entry| ids[entry[:kind].to_sym] << entry[:id] }
        expected_from_ir(payload).reject { |kind, id| ids[kind].include?(id) }.map do |kind, id|
          { kind: kind.to_s, id: id, generated: false, gap_class: "unaccounted", construct: "unaccounted",
            reason: "expected per ir.json, but manifest.json has NO entry for it at all — not even a " \
                    "recorded skip; the generator's own accounting missed this construct entirely" }
        end
      end

      # A real functional gap: not generated, or generated but unrouted.
      def functional_gap?(finding) = finding[:generated] == false || finding[:routed] == false

      # Every rule must still excuse a real gap somewhere under `src/generated/`.
      def check_allowlist
        gaps = Dir.glob(File.join(generated_root, "*/ir.json")).flat_map do |ir_path|
          coverage_findings(File.dirname(ir_path))[1].select { |finding| functional_gap?(finding) }
        end
        stale = ALLOWLIST.reject { |rule| gaps.any? { |finding| allowlist_rule_matches?(rule, finding) } }
        if stale.empty?
          puts "bin/rust_coverage --check-allowlist: all #{ALLOWLIST.size} rules still excuse a real gap"
          return 0
        end
        stale.each do |rule|
          warn "STALE ALLOWLIST RULE: #{rule.slice(:kind, :gap_class, :construct)} matches no gap in any generated " \
               "module — the gap it excused is gone; delete the rule"
        end
        1
      end

      def report(domain, codegen)
        mod_dir = File.join(generated_root, domain)
        Dir.exist?(mod_dir) or raise Failure, "#{mod_dir}: no such generated module — run bin/project_rust first, " \
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
                                                                           "re-run bin/project_rust for this domain to write it"
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
        # A construct is implemented only when generated and routed (where routing applies): a
        # `dispatch_*` that compiles but nothing can call is not working.
        implemented, remainder = findings.partition { |f| f[:generated] && f[:routed] != false }
        deferred, gap = remainder.partition { |f| allowlisted(f) }
        puts "=" * 72
        puts "bin/rust_coverage #{domain}  (source: manifest.json)"
        puts "=" * 72
        puts "#{ir.fetch(:name)} — #{findings.size} constructs accounted for " \
             "(#{implemented.size} implemented, #{deferred.size} deferred, #{gap.size} GAP)"
        print_bucket("IMPLEMENTED", implemented) unless implemented.empty?
        print_deferred(deferred)
        print_gaps(gap)
        puts
        gap.empty? ? 0 : 1
      end

      def print_bucket(label, entries)
        puts "\n#{label} (#{entries.size})"
        sorted(entries).each { |entry| print_entry(entry) }
      end

      def print_deferred(deferred)
        puts "\nDEFERRED (#{deferred.size}) — on the allowlist, with its cited reason"
        sorted(deferred).each do |entry|
          puts "  [#{entry[:kind]}] #{entry[:id]}"
          puts "      allowlist: #{allowlisted(entry)[:doc]}"
        end
      end

      def print_gaps(gap)
        puts "\nGAP (#{gap.size}) — missing, and NOT on the allowlist: a real, actionable finding"
        sorted(gap).each { |entry| print_entry(entry) }
      end

      def print_entry(entry)
        line = "  [#{entry[:kind]}] #{entry[:id]}"
        line += " (#{entry[:gap_class]})" if entry[:gap_class]
        puts line
        puts "      #{entry[:reason]}" if entry[:reason]
      end

      def sorted(entries) = entries.sort_by { |entry| [entry[:kind].to_s, entry[:id]] }
    end
  end
end
