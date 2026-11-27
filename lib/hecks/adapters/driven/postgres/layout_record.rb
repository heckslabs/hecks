require_relative "../../../runtime/errors"

module Hecks
  module Adapters
    # The layout a Postgres database keeps each domain's rows in, recorded in `hecks_layouts` by the
    # first boot that writes the domain, and compared on every later boot (ADR 0182). A domain's
    # layout cannot change once data exists, so a boot whose hecksagon chose the other layout is
    # refused, naming both. A database written before the record existed is read by its own
    # evidence: held eras mean the revision layout, an aggregate's entry log the table layout.
    class PostgresLayoutRecord
      # The metadata table that holds one row per domain.
      TABLE = "hecks_layouts".freeze

      # One row per domain: the layout its rows are kept in, and when that was recorded.
      DDL = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS #{TABLE} (
          domain      text PRIMARY KEY,
          layout      text NOT NULL,
          recorded_at timestamptz NOT NULL DEFAULT now()
        )
      SQL

      # The table layout: one table per aggregate.
      TABLE_LAYOUT = "table".freeze

      # The revision layout: the journal, the held eras and the derived heads.
      REVISION_LAYOUT = "revisions".freeze

      # What each layout's own hecksagon says, named in a refusal.
      KEEPING = {
        TABLE_LAYOUT    => "remove `revisions true` from its hecksagon",
        REVISION_LAYOUT => "keep `revisions true` in its hecksagon"
      }.freeze

      # @param db [PG::Connection] a connection whose search_path selects the domain's schema
      # @param domain [String] the domain's name, as its rows are journaled under it
      def initialize(db, domain)
        @db = db
        @domain = domain.to_s
      end

      # The layout recorded for the domain, else the one its unrecorded rows show, else nil.
      #
      # @param storage_names [Array<String>] the storage names of the aggregates the boot keeps,
      #   whose entry logs show an unrecorded table layout
      # @return [String, nil] `"table"`, `"revisions"`, or nil for a domain with no data
      def found(storage_names = [])
        recorded || evidenced(storage_names)
      end

      # Refuses a boot whose layout differs from the one the database holds for the domain. Reads
      # only, so a boot that writes nothing stays that way.
      #
      # @param layout [String] the layout this boot declares
      # @param storage_names [Array<String>] the storage names of the aggregates the boot keeps
      # @return [void]
      # @raise [Runtime::WiringError] naming both layouts, when they differ
      def check!(layout, storage_names = [])
        held = found(storage_names)
        refuse!(layout, held) if held && held != layout
      end

      # Records the domain's layout when none is recorded, after refusing one that differs.
      #
      # @param layout [String] the layout this boot writes in
      # @param storage_names [Array<String>] the storage names of the aggregates the boot keeps
      # @return [void]
      # @raise [Runtime::WiringError] naming both layouts, when the database holds the other
      def record!(layout, storage_names = [])
        check!(layout, storage_names)
        @db.exec(DDL)
        @db.exec_params("INSERT INTO #{TABLE} (domain, layout) VALUES ($1, $2) ON CONFLICT (domain) DO NOTHING",
                        [@domain, layout])
        check!(layout)
      end

      private

      def recorded
        return unless relation?(TABLE)

        row = @db.exec_params("SELECT layout FROM #{TABLE} WHERE domain = $1", [@domain]).first
        row && row["layout"]
      end

      def evidenced(storage_names)
        return REVISION_LAYOUT if held_eras?
        return TABLE_LAYOUT if storage_names.any? { |name| relation?("#{name}_entries") }

        nil
      end

      def held_eras?
        relation?("hecks_eras") &&
          @db.exec_params("SELECT 1 FROM hecks_eras WHERE domain = $1 LIMIT 1", [@domain]).ntuples.positive?
      end

      def relation?(name)
        !@db.exec_params("SELECT to_regclass($1) AS relation", [name])[0]["relation"].nil?
      end

      def refuse!(layout, held)
        raise Runtime::WiringError,
              "cannot boot #{@domain} in Postgres's #{layout} layout: its database holds #{@domain} in the " \
              "#{held} layout, and a layout cannot change once data exists. To keep the data, " \
              "#{KEEPING.fetch(held)}; to start over, point the world at a database that holds no #{@domain}."
      end
    end
  end
end
