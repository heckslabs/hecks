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
        values  = [entry.id.to_s] + persisted_fields.map { |field| encode_field(field, entry.state[field[:name]]) }
        @db.execute(
          "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{Array.new(columns.size,
                                                                                              '?').join(', ')})", values
        )
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
        eligible = model.filtered_head_names

        # Root first, always (see this method's own header): a later head's
        # join must match against a root or head already resolved.
        root_heads, other_heads = model.aggregate_heads.partition { |head| head[:aggregate] == model.reference_target }
        projected = []
        reports = {}
        (root_heads + other_heads).each do |head|
          aggregate = bluebook.aggregate(head[:aggregate])
          rows = if head[:aggregate] == model.reference_target
                   [select_projected(aggregate, reference_id) ||
                     raise(Runtime::NotFound,
                           Runtime::RefusalWording.render_site("NotFound", "read_model_reference_missing",
                                                               aggregate: head[:aggregate],
                                                               offered:   Hecks::Rendering.describe(reference_id)))]
                 else
                   select_related(aggregate, projected)
                 end
          rows = Ports::Query::InMemory.execute(rows, model.options_for(head[:as]), args) if eligible.include?(head[:as])
          projected << { aggregate: head[:aggregate], rows: rows }
          reports[head[:as]] = if head[:many]
                                 rows.map { |row| Runtime::Value.materialize(row.to_h) }
                               else
                                 rows.first && Runtime::Value.materialize(rows.first.to_h)
                               end
        end
        [reports]
      end

      private

      def select_projected(aggregate, id)
        row = @db.get_first_row("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = ?", [id.to_s])
        row && projected_instance(aggregate, row)
      end

      # Matches every already-projected source, not just the root, so a head
      # referencing another included head still matches.
      def select_related(aggregate, projected)
        matches = projected.flat_map do |source|
          references = aggregate.attributes.select do |attribute|
            attribute.reference? && attribute.type.target_name == source[:aggregate].to_s
          end
          next [] if references.empty?

          ids = source[:rows].map { |row| row.id.to_s }
          next [] if ids.empty?

          references.product(ids)
        end
        return [] if matches.empty?

        # A reference column holds the id, so it compares directly against itself.
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

      # Declared attributes plus the lifecycle field and any unlisted
      # `projects` fields, all read back raw (see `decode_fields`).
      def fields_for(aggregate)
        fields = aggregate.attributes.map { |attribute| [attribute.name, attribute] }
        if (lifecycle = aggregate.lifecycle) && fields.none? { |name, _| name == lifecycle.field }
          fields << [lifecycle.field, nil]
        end
        # `projects` fields (ADR 0025) read back raw too — see `persisted_fields`.
        aggregate.projected_fields.each do |field|
          fields << [field.name, nil] unless fields.any? { |name, _| name == field.name }
        end
        fields
      end

      # Decoded through the state codec against the row's own aggregate —
      # see Codec#decode for why a NULL projected-only column reads back absent.
      def decode_fields(fields, aggregate, row)
        state = fields.each_with_object({}) do |(name, attribute), raw_state|
          raw = row[name.to_s]
          # rubocop:disable Lint/DuplicateBranch -- the nil-attribute and
          # reference-id branches both just answer `raw`, for unrelated reasons.
          next if attribute.nil? && raw.nil? && aggregate.lifecycle&.field&.to_sym != name.to_sym

          raw_state[name] =
            if attribute.nil?
              raw
            elsif attribute.list? || !aggregate.value_object(attribute.type).nil?
              raw ? JSON.parse(raw) : nil
            else
              # A reference is a scalar id — see Codec#decode.
              raw
            end
          # rubocop:enable Lint/DuplicateBranch
        end
        Ports::Persistence::StateCodec.decode(aggregate, state)
      end
    end
  end
end
