# frozen_string_literal: true

require_relative "census"

module Hecks
  module Adapters
    module Rehearsal
      # Counts what a Postgres copy holds for the domain without creating anything: a plain
      # connection, the schemas looked up before one is chosen, and counts over the relations that
      # exist. A schema that is not in the copy is reported, never created.
      class PostgresCensus
        JOURNAL_LATEST = <<~SQL
          SELECT aggregate, count(*) AS live FROM (
            SELECT DISTINCT ON (aggregate, aggregate_id) aggregate, operation
            FROM %<journal>s ORDER BY aggregate, aggregate_id, ordinal DESC
          ) latest WHERE operation = 'save' GROUP BY aggregate
        SQL

        # @param url [String] the copy's database URL
        # @param subject [Subject] the loaded domain
        # @param candidates [Array<Array(String, String)>] schema and source, in the order tried
        def initialize(url, subject, candidates)
          @url = url
          @subject = subject
          @candidates = candidates
        end

        # @return [Census] the counts, in the first candidate schema that holds a lineage, else the
        #   first that exists, else the first named
        def read
          db = PG.connect(@url)
          present = schemas(db)
          lineage = holders(db)
          name, source = choose(present, lineage)
          return absent(name, source, lineage) unless present.include?(name)

          db.exec("SET search_path TO #{db.quote_ident(name)}")
          counted(db, name, source, lineage - [name])
        ensure
          db&.close
        end

        private

        def schemas(db) = db.exec("SELECT schema_name FROM information_schema.schemata").map { |row| row["schema_name"] }

        def holders(db)
          sql = "SELECT table_schema FROM information_schema.tables WHERE table_name = 'hecks_eras'"
          db.exec(sql).map { |row| row["table_schema"] }.sort
        end

        def choose(present, lineage)
          @candidates.find { |name, _| lineage.include?(name) } || @candidates.find { |name, _| present.include?(name) } ||
            @candidates.first
        end

        def absent(name, source, lineage)
          Census.new(schema: name, source: source, present: false, eras: 0, journal_entries: 0,
                     counts: empty_counts, elsewhere: lineage)
        end

        def empty_counts = @subject.aggregates.map { |a| Census::Count.new(aggregate: a.name, head: 0, journal: 0) }

        def counted(db, name, source, elsewhere)
          lineage = PostgresEra::Lineage.new(db, @subject.bluebook_name)
          Census.new(schema: name, source: source, present: true, eras: eras(db), counts: counts(db, lineage),
                     journal_entries: rows(db, lineage.journal), elsewhere: elsewhere)
        end

        def counts(db, lineage)
          live = latest(db, lineage)
          @subject.aggregates.map do |aggregate|
            Census::Count.new(aggregate: aggregate.name, head: rows(db, lineage.head_view(aggregate.storage_name)),
                              journal: live.fetch(aggregate.storage_name, 0))
          end
        end

        def eras(db)
          return 0 unless relation?(db, "hecks_eras")

          db.exec_params("SELECT count(*) FROM hecks_eras WHERE domain = $1", [@subject.bluebook_name])[0]["count"].to_i
        end

        def latest(db, lineage)
          return {} unless relation?(db, lineage.journal)

          db.exec(format(JOURNAL_LATEST, journal: db.quote_ident(lineage.journal))).to_h { |r| [r["aggregate"], r["live"].to_i] }
        end

        def rows(db, name)
          relation?(db, name) ? db.exec("SELECT count(*) FROM #{db.quote_ident(name)}")[0]["count"].to_i : 0
        rescue PG::Error
          0
        end

        def relation?(db, name) = !db.exec_params("SELECT to_regclass($1) AS found", [db.quote_ident(name)])[0]["found"].nil?
      end
    end
  end
end
