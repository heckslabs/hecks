require_relative "../../../runtime/instance"
require_relative "../../../runtime/value"
require_relative "../../../runtime/errors"
require_relative "../../../runtime/refusal_wording"
require_relative "../../../rendering"
require_relative "../../../ports/query/in_memory"
require_relative "row_decoding"

module Hecks
  module Adapters
    # What a projection adapter shares, whatever its SQL dialect.
    module Projection
      # The read-model answer a projection gives from its own tables, the same walk
      # `Runtime::ReadModelInterpreter` makes in process (ADR 0122 checks they agree).
      #
      # The including adapter supplies `projected_row(aggregate, id)`, the raw row for one id
      # or nil, and `related_rows(aggregate, matches)`, the raw rows whose reference column
      # holds any of the `[attribute, id]` pairs, ordered by id; `RowDecoding` turns each row
      # into an instance through the adapter's own `decode_column`.
      module ReadModelWalk
        include RowDecoding

        # The state of one `query_read_model` call, threaded through its per-head steps.
        ReadModelRun = Struct.new(:model, :args, :bluebook, :reference_id, :eligible, :projected)

        # Executes a declared read model against the projected read-store tables.
        #
        # A missing root raises, matching the in-process interpreter; a head
        # matches against any already-projected source, not only the root.
        #
        # @param _domain [String, Symbol] domain name; not read
        # @param model [Bluebook::ReadModel, Runtime::TenantScope::Scoped] read model to answer
        # @param args [Hash] arguments; `model.reference_name` holds the root id
        # @param bluebook [Bluebook::Chapter, nil] resolves each included aggregate; nil refused
        # @return [Array<Hash>] one-element Array of the report, keyed by each head's `as`
        # @raise [ArgumentError] if bluebook is nil
        # @raise [Runtime::NotFound] if no projected row matches the referenced root id
        def query_read_model(_domain, model, args, bluebook = nil)
          raise ArgumentError, "projection query needs its domain bluebook" unless bluebook

          # Read the same way ReadModelInterpreter reads it: an identity is a
          # declared path, not unwrapped.
          reference_id = args.fetch(model.reference_name).to_s
          # Plural (ADR 0055): `on:` lets `where`/`order_by`/`limit`/`offset`
          # each name a different many-side head, so more than one may be
          # eligible in the same read model.
          run = ReadModelRun.new(model, args, bluebook, reference_id, model.filtered_head_names, [])
          [ordered_heads(model).to_h { |head| [head[:as], resolve_head(run, head)] }]
        end

        private

        # Root first, always (see `query_read_model`'s own header): a later head's
        # join must match against a root or head already resolved.
        def ordered_heads(model)
          root_heads, other_heads = model.aggregate_heads.partition { |head| head[:aggregate] == model.reference_target }
          root_heads + other_heads
        end

        # Reads one head's rows, records them as projected so later heads can join against them,
        # and returns the head's report entry.
        def resolve_head(run, head)
          rows = head_rows(run, head, run.bluebook.aggregate(head[:aggregate]))
          rows = filter_rows(run, head, rows)
          run.projected << { aggregate: head[:aggregate], rows: rows }
          head_report(head, rows)
        end

        # Applies the head's `where`/`order_by`/`limit`/`offset` when the read model names it.
        def filter_rows(run, head, rows)
          return rows unless run.eligible.include?(head[:as])

          Ports::Query::InMemory.execute(rows, run.model.options_for(head[:as]), run.args)
        end

        def head_report(head, rows)
          return rows.map { |row| Runtime::Value.materialize(row.to_h) } if head[:many]

          rows.first && Runtime::Value.materialize(rows.first.to_h)
        end

        def head_rows(run, head, aggregate)
          model = run.model
          return select_related(aggregate, run.projected) unless head[:aggregate] == model.reference_target

          [select_projected(aggregate, run.reference_id) || raise(Runtime::NotFound, missing_root_wording(run, head))]
        end

        def missing_root_wording(run, head)
          Runtime::RefusalWording.render_site("NotFound", "read_model_reference_missing",
                                              aggregate: head[:aggregate],
                                              offered:   Hecks::Rendering.describe(run.reference_id))
        end

        def select_projected(aggregate, id)
          row = projected_row(aggregate, id.to_s)
          row && projected_instance(aggregate, row)
        end

        # Matches every already-projected source, not just the root, so a head
        # referencing another included head still matches. A head that names no aggregate of the
        # chapter (an entity, such as the language's `Handler`) has no rows, as the in-process loop
        # reads it.
        def select_related(aggregate, projected)
          return [] unless aggregate

          matches = projected.flat_map { |source| reference_matches(aggregate, source) }
          return [] if matches.empty?

          related_rows(aggregate, matches).map { |row| projected_instance(aggregate, row) }
        end

        # Every (reference attribute, id) pair by which `aggregate` points at one projected source.
        def reference_matches(aggregate, source)
          references = aggregate.attributes.select do |attribute|
            attribute.target_name == source[:aggregate].to_s
          end
          return [] if references.empty?

          ids = source[:rows].map { |row| row.id.to_s }
          references.product(ids)
        end
      end
    end
  end
end
