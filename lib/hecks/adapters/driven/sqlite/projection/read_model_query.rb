require_relative "../../../../runtime/errors"
require_relative "../../../../runtime/refusal_wording"
require_relative "../../../../rendering"
require_relative "../../../../ports/query/in_memory"

module Hecks
  module Adapters
    class SqliteProjection
      # `SqliteProjection#query_read_model` and its own private assembly —
      # split out of the class body only to keep that class under its line
      # budget; every method here stays private on `SqliteProjection`
      # instances exactly as if it were still defined there.
      module ReadModelQuery
        # Execute a declared read model against the projected aggregate-head
        # tables. The report shape is assembled from SQL-selected rows, rather
        # than scanning repositories and matching references in Ruby.
        #
        # M19 (docs/audits/2026-08-10-main-bug-audit.md,
        # docs/audits/2026-08-11-bug-triage.md) — this agrees with
        # `Runtime::ReadModelInterpreter#project` (the in-process path) on
        # the two counts where a native path can most easily diverge:
        #
        # **Missing root**: the in-process path's own `fetch` refuses with
        # `NotFound` when the reference argument names no record, and so
        # does this. Answering a silent `{root: nil, ...}` instead would
        # make this the one path where a caller could dispatch a read model
        # against a record that never existed and get back something that
        # looks like an empty report rather than the refusal every other
        # path gives.
        #
        # **Chained-include join scope**: matching a non-root head against
        # the root's own id alone, regardless of what it actually
        # references, is correct for a head that references the root
        # directly and silently empty for one that references another
        # included head instead (`Leaf` -> `Mid` -> `Root`, `Leaf` itself
        # has no attribute referencing `Root` at all, so its `references`
        # would always be `[]`). The in-process path
        # (`ReadModelInterpreter#project`'s "root first, always" comment)
        # matches a head against any already-projected source, not
        # only the root — `select_related` does the same: each head is
        # matched against every source resolved so far (root first, then
        # declared order — the same one-level-of-declaration-order
        # dependency the in-process path itself has, documented
        # there as L2, not a gap introduced here).
        #
        # @param _domain [String, Symbol] name of the domain declaring the read model; not read
        # @param model [Bluebook::ReadModel, Runtime::TenantScope::Scoped] the read model to
        #   answer, or the tenant-scoping delegator around one; must have a reference target
        # @param args [Hash{Symbol => Object}] the read model's arguments; the entry under
        #   `model.reference_name` is the root record's id
        # @param bluebook [Bluebook::Chapter, nil] the domain's bluebook, which resolves each
        #   included aggregate by name; nil is refused
        # @return [Array<Hash>] a one-element Array holding the report Hash, keyed by each
        #   head's `as` name: an Array of plain state Hashes (each with `:id`) for a `many`
        #   head, otherwise one such Hash, or nil when that head matched no row
        # @raise [ArgumentError] if `bluebook` is nil
        # @raise [KeyError] if `args` has no entry for the model's reference argument
        # @raise [Runtime::NotFound] if no projected row has the referenced root id
        # @raise [SQLite3::Exception] if a statement fails
        def query_read_model(_domain, model, args, bluebook = nil)
          raise ArgumentError, "projection query needs its domain bluebook" unless bluebook

          # The reference's own shape, read the same way ReadModelInterpreter
          # reads it — not the identity unwrap, which is gone : an identity is
          # declared as a path and followed.
          reference_id = args.fetch(model.reference_name).to_s
          # Plural (ADR 0055) — `on:` lets `where`/`order_by`/`limit`/`offset`
          # each name a different many-side head, so more than one can be
          # eligible in the same read model now.
          ctx = ReadModelContext.new(model: model, bluebook: bluebook, args: args, eligible: model.filtered_head_names)
          [assemble_reports(ctx, reference_id)]
        end

        private

        # Bundles `query_read_model`'s own call-scoped, unchanging lookups
        # (the read model itself, its bluebook, the raw args, and which
        # heads a `where`/`order_by`/`limit`/`offset` targets) so the
        # per-head helpers below take one value instead of a four-wide
        # parameter list repeated at every call site.
        ReadModelContext = Struct.new(:model, :bluebook, :args, :eligible, keyword_init: true)
        private_constant :ReadModelContext

        # **Root first, always** — see `query_read_model`'s own header. Mirrors
        # `ReadModelInterpreter#project`'s identical partition, for the
        # identical reason: a later head's own join has to be able to
        # match against a root (or another head) already resolved.
        def assemble_reports(ctx, reference_id)
          reports = {}
          projected = []
          ordered_heads(ctx).each do |head|
            rows = rows_for_head(ctx, head, reference_id, projected)
            projected << { aggregate: head[:aggregate], rows: rows }
            reports[head[:as]] = report_value_for(head, rows)
          end
          reports
        end

        def ordered_heads(ctx)
          root_heads, other_heads = ctx.model.aggregate_heads.partition do |head|
            head[:aggregate] == ctx.model.reference_target
          end
          root_heads + other_heads
        end

        def rows_for_head(ctx, head, reference_id, projected)
          aggregate = ctx.bluebook.aggregate(head[:aggregate])
          rows = if head[:aggregate] == ctx.model.reference_target
                   [root_row(aggregate, head, reference_id)]
                 else
                   select_related(aggregate, projected)
                 end
          return rows unless ctx.eligible.include?(head[:as])

          Ports::Query::InMemory.execute(rows, ctx.model.options_for(head[:as]), ctx.args)
        end

        def root_row(aggregate, head, reference_id)
          select_projected(aggregate, reference_id) ||
            raise(Runtime::NotFound,
                  Runtime::RefusalWording.render_site("NotFound", "read_model_reference_missing",
                                                      aggregate: head[:aggregate],
                                                      offered:   Hecks::Rendering.describe(reference_id)))
        end

        def report_value_for(head, rows)
          return rows.map { |row| Runtime::Value.materialize(row.to_h) } if head[:many]

          rows.first && Runtime::Value.materialize(rows.first.to_h)
        end
      end
    end
  end
end
