require_relative "../../../runtime/instance"
require_relative "../../../runtime/value"

# The subclass needs its parent — and sqlite.rb requires this file at
# its bottom, after class Sqlite is defined, so the require cycle this
# creates resolves correctly from either entry point.
require_relative "../sqlite"
require_relative "projection/read_model_query"

module Hecks
  module Adapters
    # Rebuilds a read store from the authoritative journal, entry by entry.
    # A value object is written as its JSON object and a reference as the
    # bare id it holds — the same shapes the command path writes, so there
    # is no second representation to accept here any more. `query_read_model`
    # and its own private assembly live in the sibling `ReadModelQuery`
    # module (split out only to keep this class under its line budget).
    class SqliteProjection < Sqlite
      include ReadModelQuery

      # Replaces or deletes the read store's row for one journal entry, encoding the entry's
      # state directly rather than through a `Runtime::Instance`.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @return [Ports::Persistence::Entry, Array] the same `entry` for a save; for a delete,
      #   the `DELETE` statement's empty result rows
      # @raise [SQLite3::Exception] if the statement fails
      def project(entry)
        return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

        insert_or_replace_row(entry)
        entry
      end

      private

      def insert_or_replace_row(entry)
        columns = insert_columns
        slots   = Array.new(columns.size, "?").join(", ")
        @db.execute("INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{slots})",
                    insert_values(entry))
      end

      def insert_columns
        (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
      end

      def insert_values(entry)
        [entry.id.to_s] + persisted_fields.map { |field| encode_field(field, entry.state[field[:name]]) }
      end

      def select_projected(aggregate, id)
        row = @db.get_first_row("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = ?", [id.to_s])
        row && projected_instance(aggregate, row)
      end

      # Matched against every source already projected (root first, then
      # declared order — see this class's own `query_read_model` header),
      # not only the root — a head whose own reference points at another
      # included head rather than the root directly would otherwise match
      # nothing at all, since its reference attribute would be compared
      # against a target (the root) it never names.
      def select_related(aggregate, projected)
        matches = matching_reference_pairs(aggregate, projected)
        return [] if matches.empty?

        rows_for_matches(aggregate, matches)
      end

      def matching_reference_pairs(aggregate, projected)
        projected.flat_map { |source| reference_pairs_for_source(aggregate, source) }
      end

      def reference_pairs_for_source(aggregate, source)
        references = aggregate.attributes.select do |attribute|
          attribute.reference? && attribute.type.target_name == source[:aggregate].to_s
        end
        return [] if references.empty?

        ids = source[:rows].map { |row| row.id.to_s }
        return [] if ids.empty?

        references.product(ids)
      end

      # A reference column holds the ID, so it compares as itself. The
      # `json_extract(col,'$.value') = ? OR col = ?` this replaced was
      # reading both shapes because both existed — one written by the
      # command path, one by older journals. There is one shape now.
      def rows_for_matches(aggregate, matches)
        clauses = matches.map { |attribute, _id| "#{quote_ident(attribute.name)} = ?" }
        bind = matches.map { |_attribute, id| id }
        @db.execute("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE #{clauses.join(' OR ')} ORDER BY id", bind)
           .map { |row| projected_instance(aggregate, row) }
      end

      def projected_instance(aggregate, row)
        Runtime::Instance.new(aggregate: aggregate, id: row["id"], state: decode_for(aggregate, row))
      end

      def decode_for(aggregate, row)
        decode_fields(fields_for(aggregate), aggregate, row)
      end

      # The field list a row decodes against: every declared attribute,
      # plus the lifecycle field and any `projects` fields not already
      # among them (both read back raw — see `decode_fields`).
      def fields_for(aggregate)
        fields = aggregate.attributes.map { |attribute| [attribute.name, attribute] }
        append_lifecycle_field_pair!(fields, aggregate)
        append_projected_field_pairs!(fields, aggregate)
        fields
      end

      def append_lifecycle_field_pair!(fields, aggregate)
        lifecycle = aggregate.lifecycle
        return unless lifecycle
        return if fields.any? { |name, _| name == lifecycle.field }

        fields << [lifecycle.field, nil]
      end

      # `projects` fields (S12, ADR 0025) need reading back too — `project`
      # (above) already writes one into its own column via `persisted_fields`
      # (`Codec#persisted_fields`, this class's own superclass module), but
      # this method built its own independent field list that never
      # consulted it — a column `project` populated correctly, silently
      # dropped on every read back out. Same raw-passthrough treatment as
      # the lifecycle field just above: `attribute: nil` down in the loop.
      def append_projected_field_pairs!(fields, aggregate)
        aggregate.projected_fields.each do |field|
          fields << [field.name, nil] unless fields.any? { |name, _| name == field.name }
        end
      end

      # Decoded through the state codec (PR A3) against the row's own
      # aggregate — see Codec#decode, including why a NULL projected-only
      # column reads back absent.
      def decode_fields(fields, aggregate, row)
        state = fields.each_with_object({}) do |(name, attribute), raw_state|
          decode_field_pair_into(raw_state, name, attribute, aggregate, row)
        end
        Ports::Persistence::StateCodec.decode(aggregate, state)
      end

      def decode_field_pair_into(raw_state, name, attribute, aggregate, row)
        raw = row[name.to_s]
        return if attribute.nil? && raw.nil? && aggregate.lifecycle&.field&.to_sym != name.to_sym

        raw_state[name] = decode_field_pair_value(attribute, aggregate, raw)
      end

      # rubocop:disable Lint/DuplicateBranch -- the nil-attribute and
      # reference-id branches both just answer `raw`, coincidentally, for
      # two unrelated reasons (see each branch's own comment); merging
      # them would blur that distinction.
      def decode_field_pair_value(attribute, aggregate, raw)
        if attribute.nil?
          raw
        elsif attribute.list? || !aggregate.value_object(attribute.type).nil?
          raw ? JSON.parse(raw) : nil
        else
          # A reference is a scalar id — see Codec#decode.
          raw
        end
      end
      # rubocop:enable Lint/DuplicateBranch
    end
  end
end
