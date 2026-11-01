# frozen_string_literal: true

require_relative "subject"
require_relative "memory_store"
require_relative "postgres_store"
require_relative "rust_audit"
require_relative "audit_report"

module Hecks
  module Adapters
    module Rehearsal
      # The two questions a rehearsal asks of a subject and its data copy: where the shape stands
      # (`survey`) and what the mint's audit would refuse (`examine`). Each answer is the facts, as
      # the `RehearsalRun` commands take them.
      class Inquiry
        # What every rehearsal says it did not check.
        ENGINE_LIMIT = { what: "the Rust host's mint audit",
                         why:  "no validate_harness was built, so the Ruby audit alone ran over the rows" }.freeze

        ALWAYS = [
          { what: "the mint itself",
            why:  "no era was written: the edge, its approval and the audit were evaluated, nothing minted" },
          { what: "commands, policies and requests", why: "no traffic was run: only the stored data and the shape were read" },
          { what: "data written after the copy was made", why: "a copy is a moment; the mint sees the data of its own" }
        ].freeze

        # @param subject [Subject] the loaded domain
        # @param store [MemoryStore, PostgresStore] its prepared data copy
        def initialize(subject, store)
          @subject = subject
          @store = store
        end

        # @return [Hash] `booted`, `host_version`, `store`, `mode`, `before`, `after`, `minting`,
        #   the schema and environment that were read, and what the copy holds
        def survey
          shape.merge(environment_loaded: @subject.environment_facts, copy_note: plain(copy_note)).merge(copy_facts)
        end

        # @return [Hash] the edge facts, every refused row and its total, what was read, the parity
        #   of the two engines, and what was not checked
        def examine
          edge = decided_edge
          refusals, after = edge ? @store.audit(@subject, edge) : [[], {}]
          refusals = coverage_refusals(edge) + refusals
          rust = RustAudit.call(@subject, after)
          report = AuditReport.new(minting: minting, edge: edge, states: after, ruby: refusals, rust: rust)
          answer(edge, report, (refusals + rust.violations).uniq, limits(rust, report))
        end

        private

        def plain(value) = { value: value }

        # The edge a mint would use, as the shared decision names it; nil unless it would mint.
        def decided_edge
          return unless minting == "next" && latest[:held_text]

          verdict = resolution.verdict
          verdict&.verdict == "would_mint" ? verdict.edge : nil
        end

        # What the mint's coverage check would refuse of the decided edge, in the same words: a
        # change in the shape that no rule of the edge explains. The mint raises it before it
        # writes an era.
        def coverage_refusals(edge)
          return [] unless edge

          held = PostgresEra::LineageManager.held_bluebook(latest)
          PostgresEra::LineageManager.check_coverage!(@subject.registry, @subject.bluebook, held, edge)
          []
        rescue Runtime::WiringError => e
          [e.message]
        end

        def shape
          { booted: flag(true), host_version: plain(Rehearsal.host_version), store: plain(@subject.store_kind),
            mode: plain(@subject.copy_mode), before: plain(before), after: plain(@subject.label),
            minting: plain(minting) }
        end

        def answer(edge, report, refused, unchecked)
          rows, total = Rows.from(refused)
          edge_facts(edge).merge(refused_rows: rows, refusal_total: plain(total), parity: report.parity,
                                 unchecked: unchecked).merge(report.facts)
        end

        def flag(value) = plain(value)

        def census = @census ||= @store.census(@subject)

        def copy_note
          domain = @subject.bluebook_name
          copy_empty? ? census.refusal(domain) : census.summary(domain)
        end

        def copy_empty?
          census.empty? && @subject.copy_mode != "empty" && @subject.aggregates.any?
        end

        # The copy is empty when a dump or a readonly copy was asked for and it holds no row of a
        # domain that declares aggregates; a mode of `empty` is asked to hold nothing.
        def copy_facts = census.facts.merge(copy_empty: flag(copy_empty?))

        def edge_facts(edge)
          { minting: plain(minting), edge_present: flag(!edge.nil?) }
        end

        def eras = @eras ||= @store.eras(@subject)

        def latest = @latest ||= eras.last && @subject.held.named(eras.last)

        def before = latest ? latest[:label] : "none"

        # Which held era the shape resolves to, by the resolution a boot records; the latest era is
        # named as it would be minted.
        def resolution
          @resolution ||= @subject.resolve([*eras[0...-1], latest]) { @store.watermark(@subject) }
        end

        def minting
          return "first" unless latest

          resolution.status == "current" ? "none" : "next"
        end

        def limits(rust, report)
          engine = rust.ran ? [] : [ENGINE_LIMIT]
          engine + report.limits + ALWAYS + [journal_limit] + attached_limits +
            (@subject.held.capable? ? [] : [binding_note])
        end

        # The audit reads the journal's latest entry of each record, never the head tables.
        def journal_limit
          { what: "the head tables",
            why:  "the audit reads each record's latest journal entry (hecks_journal_<domain>_era_N), not the head " \
                  "tables, so an edit to a head table is not seen. The copy holds #{census.head_rows} head rows " \
                  "and #{census.journal_rows} journal records#{divergence}" }
        end

        def divergence
          census.head_rows == census.journal_rows ? "." : ": they differ, and only the journal's are audited."
        end

        # The bluebooks loaded beside the domain's own (a vendored package): the host holds eras
        # for the domain's own aggregates only, so theirs can neither mint nor be refused.
        def attached_limits
          names = @subject.bluebook_names - [@subject.bluebook_name]
          return [] if names.empty?

          [{ what: "the shape of the attached bluebooks (#{names.sort.join(", ")})",
             why:  "their aggregates have no era row of their own, so a change to them is not a mint" }]
        end

        def binding_note
          { what: "that a boot would mint", why: "the domain is bound to #{@subject.adapter_name}, which holds no eras " \
                                                 "in this environment" }
        end
      end
    end
  end
end
