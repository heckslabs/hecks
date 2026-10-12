# frozen_string_literal: true

require_relative "subject"
require_relative "memory_store"
require_relative "postgres_store"
require_relative "rust_audit"

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
          { what: "an edge's coverage of every change in the shape", why: "the mint checks it; the rehearsal does not yet" },
          { what: "commands, policies and requests", why: "no traffic was run: only the stored data and the shape were read" },
          { what: "data written after the copy was made", why: "a copy is a moment; the mint sees the data of its own" }
        ].freeze

        # @param subject [Subject] the loaded domain
        # @param store [MemoryStore, PostgresStore] its prepared data copy
        def initialize(subject, store)
          @subject = subject
          @store = store
        end

        # @return [Hash] `booted`, `host_version`, `store`, `mode`, `before`, `after`, `minting`
        def survey
          { booted: flag(true), host_version: plain(Rehearsal.host_version), store: plain(@subject.declaration.kind),
            mode: plain(@subject.declaration.mode), before: plain(before), after: plain(@subject.label),
            minting: plain(minting) }
        end

        # @return [Hash] the edge facts, every refused row and its total, the parity of the two
        #   engines, and what was not checked
        def examine
          edge = minting == "next" ? @subject.edge_from(before) : nil
          refusals, after = edge ? @store.audit(@subject, edge) : [[], {}]
          rust = RustAudit.call(@subject, after)
          rows, total = Rows.from(merged(refusals, rust.violations))
          edge_facts(edge).merge(refused_rows: rows, refusal_total: plain(total), parity: parity(refusals, rust),
                                 unchecked: limits(edge, rust))
        end

        private

        def plain(value) = { value: value }

        def edge_facts(edge)
          { minting: plain(minting), edge_present: flag(!edge.nil?), edge_approved: flag(approved?(edge)) }
        end

        def flag(value) = plain(value)

        def eras = @eras ||= @store.eras(@subject)

        def latest = @latest ||= eras.last && @subject.held.named(eras.last)

        def before = latest ? latest[:label] : "none"

        def minting
          return "first" unless latest

          before == @subject.label ? "none" : "next"
        end

        def approved?(edge)
          return false unless edge

          !Translation::ApprovalFile.needs_rehearsal?(edge) ||
            !Translation::ApprovalFile.applicable(@subject.directory, edge).nil?
        end

        # The refusals of both engines, each wording once: a row both refuse in the same words is
        # one row, and a row they refuse for different reasons is two.
        def merged(ruby, rust) = (ruby + rust).uniq

        def parity(ruby, rust)
          return { engine: "rust", status: "not_run", note: rust.note } unless rust.ran

          { engine: "rust", status: records(ruby) == records(rust.violations) ? "agree" : "differ",
            note: "ruby refused #{records(ruby).size} records, rust #{records(rust.violations).size}" }
        end

        def records(refusals) = refusals.map { |text| text[/\A[^:]+/] }.uniq.sort

        def limits(edge, rust)
          engine = rust.ran ? [] : [ENGINE_LIMIT]
          engine + ALWAYS + @store.limits(edge) + attached_limits + (@subject.held.capable? ? [] : [binding_note])
        end

        # The chapters loaded beside the domain's own (a vendored package): the host holds eras
        # for the domain's own aggregates only, so theirs can neither mint nor be refused.
        def attached_limits
          names = @subject.held.registry.bluebooks.values.map(&:name) - [@subject.bluebook.name]
          return [] if names.empty?

          [{ what: "the shape of the attached chapters (#{names.sort.join(", ")})",
             why:  "their aggregates have no era row of their own, so a change to them is not a mint" }]
        end

        def binding_note
          { what: "that a boot would mint", why: "the domain is bound to #{@subject.held.adapter_name}, which holds no eras " \
                                                 "in this environment" }
        end
      end
    end
  end
end
