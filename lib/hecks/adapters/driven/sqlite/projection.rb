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
    # A value object is written as its JSON object and a reference as the
    # bare id it holds — the same shapes the command path writes, so there
    # is no second representation to accept here any more.
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
        eligible = model.filtered_head_names

        # **Root first, always** — see this method's own header. Mirrors
        # `ReadModelInterpreter#project`'s identical partition, for the
        # identical reason: a later head's own join has to be able to
        # match against a root (or another head) already resolved.
        root_heads, other_heads = model.aggregate_heads.partition { |head| head[:aggregate] == model.reference_target }
        projected = []
        reports = {}
        (root_heads + other_heads).each do |head|
          aggregate = bluebook.aggregate(head[:aggregate])
          rows = if head[:aggregate] == model.reference_target
                   [select_projected(aggregate, reference_id) ||
                     raise(Runtime::NotFound,
                           Runtime::RefusalWording.render("NotFound", "read_model_reference_missing",
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

      # Matched against every source already projected (root first, then
      # declared order — see this class's own `query_read_model` header),
      # not only the root — a head whose own reference points at another
      # included head rather than the root directly would otherwise match
      # nothing at all, since its reference attribute would be compared
      # against a target (the root) it never names.
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

        # A reference column holds the ID, so it compares as itself. The
        # `json_extract(col,'$.value') = ? OR col = ?` this replaced was
        # reading both shapes because both existed — one written by the
        # command path, one by older journals. There is one shape now.
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
        if (lifecycle = aggregate.lifecycle) && fields.none? { |name, _| name == lifecycle.field }
          fields << [lifecycle.field, nil]
        end
        # `projects` fields (S12, ADR 0025) need reading back too — `project`
        # (above) already writes one into its own column via `persisted_fields`
        # (`Codec#persisted_fields`, this class's own superclass module), but
        # this method built its own independent field list that never
        # consulted it — a column `project` populated correctly, silently
        # dropped on every read back out. Same raw-passthrough treatment as
        # the lifecycle field just above: `attribute: nil` down in the loop.
        aggregate.projected_fields.each do |field|
          fields << [field.name, nil] unless fields.any? { |name, _| name == field.name }
        end
        fields
      end

      # Decoded through the state codec (PR A3) against the row's own
      # aggregate — see Codec#decode, including why a NULL projected-only
      # column reads back absent.
      def decode_fields(fields, aggregate, row)
        state = fields.each_with_object({}) do |(name, attribute), raw_state|
          raw = row[name.to_s]
          # rubocop:disable Lint/DuplicateBranch -- the nil-attribute and
          # reference-id branches both just answer `raw`, coincidentally, for
          # two unrelated reasons (see each branch's own comment); merging
          # them would blur that distinction.
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
