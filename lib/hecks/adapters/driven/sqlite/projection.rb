require_relative "../../../runtime/instance"
require_relative "../../../runtime/value"
require_relative "../../../runtime/errors"
require_relative "../../../runtime/refusal_wording"
require_relative "../../../rendering"
require_relative "../../../ports/query/in_memory"

# The subclass needs its parent — and sqlite.rb requires this file at
# its bottom, after class Sqlite is defined, so the require cycle this
# creates resolves correctly from either entry point.
require_relative "../sqlite"

module Hecks
  module Adapters
    # Rebuilds a read store from the authoritative journal, entry by entry.
    # Values are written as JSON, references as bare ids — the shapes the command path writes.
    class SqliteProjection < Sqlite
      # The state of one `query_read_model` call, threaded through its per-head steps.
      ReadModelRun = Struct.new(:model, :args, :bluebook, :reference_id, :eligible, :projected)

      # Replaces or deletes the read store's row for one journal entry, encoding the entry's
      # state directly rather than through a `Runtime::Instance`.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @return [Ports::Persistence::Entry, Array] the same `entry` for a save; for a delete,
      #   the `DELETE` statement's empty result rows
      # @raise [SQLite3::Exception] if the statement fails
      def project(entry)
        return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

        columns = (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
        @db.execute(upsert_sql(columns), row_values(entry))
        entry
      end

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
        # Plural (ADR 0055) — `on:` lets `where`/`order_by`/`limit`/`offset`
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
        return select_related(aggregate, run.projected) unless head[:aggregate] == run.model.reference_target

        [select_projected(aggregate, run.reference_id) || raise(Runtime::NotFound, missing_root_wording(run, head))]
      end

      def missing_root_wording(run, head)
        Runtime::RefusalWording.render_site("NotFound", "read_model_reference_missing",
                                            aggregate: head[:aggregate],
                                            offered:   Hecks::Rendering.describe(run.reference_id))
      end

      def row_values(entry)
        [entry.id.to_s] + persisted_fields.map { |field| encode_field(field, entry.state[field[:name]]) }
      end

      def select_projected(aggregate, id)
        row = @db.get_first_row("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = ?", [id.to_s])
        row && projected_instance(aggregate, row)
      end

      # Matches every already-projected source, not just the root, so a head
      # referencing another included head still matches.
      def select_related(aggregate, projected)
        matches = projected.flat_map { |source| reference_matches(aggregate, source) }
        return [] if matches.empty?

        # A reference column holds the id, so it compares directly against itself.
        clauses = matches.map { |attribute, _id| "#{quote_ident(attribute.name)} = ?" }
        bind = matches.map { |_attribute, id| id }
        @db.execute("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE #{clauses.join(" OR ")} ORDER BY id", bind)
           .map { |row| projected_instance(aggregate, row) }
      end

      # Every (reference attribute, id) pair by which `aggregate` points at one projected source.
      def reference_matches(aggregate, source)
        references = aggregate.attributes.select do |attribute|
          attribute.reference? && attribute.type.target_name == source[:aggregate].to_s
        end
        return [] if references.empty?

        ids = source[:rows].map { |row| row.id.to_s }
        references.product(ids)
      end

      def projected_instance(aggregate, row)
        Runtime::Instance.new(aggregate: aggregate, id: row["id"], state: decode_for(aggregate, row))
      end

      def decode_for(aggregate, row)
        decode_fields(fields_for(aggregate), aggregate, row)
      end

      # Declared attributes plus the lifecycle field and any unlisted
      # `projects` fields, all read back raw (see `decode_fields`).
      def fields_for(aggregate)
        fields = aggregate.attributes.map { |attribute| [attribute.name, attribute] }
        # `projects` fields (ADR 0025) read back raw too — see `persisted_fields`.
        lifecycle = aggregate.lifecycle
        raw_names = (lifecycle ? [lifecycle.field] : []) + aggregate.projected_fields.map(&:name)
        raw_names.each { |raw| fields << [raw, nil] unless fields.any? { |name, _| name == raw } }
        fields
      end

      # Decoded through the state codec against the row's own aggregate —
      # see Codec#decode for why a NULL projected-only column reads back absent.
      def decode_fields(fields, aggregate, row)
        state = fields.each_with_object({}) do |(name, attribute), raw_state|
          raw = row[name.to_s]
          next if unset_projected?(aggregate, name, attribute, raw)

          raw_state[name] = decode_column(aggregate, attribute, raw)
        end
        Ports::Persistence::StateCodec.decode(aggregate, state)
      end

      # A NULL column with no attribute reads back absent, except the lifecycle field.
      def unset_projected?(aggregate, name, attribute, raw)
        attribute.nil? && raw.nil? && aggregate.lifecycle&.field&.to_sym != name.to_sym
      end

      def decode_column(aggregate, attribute, raw)
        return raw if attribute.nil?
        # A reference is a scalar id — see Codec#decode.
        return raw unless attribute.list? || !aggregate.value_object(attribute.type).nil?

        raw ? JSON.parse(raw) : nil
      end
    end
  end
end
