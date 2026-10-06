module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The DDL of the lineage tables and the journal, run once per boot, owner only.
        module BaseSql
          # The held eras of every domain.
          ERAS_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS hecks_eras (
              domain    text NOT NULL,
              ordinal   int  NOT NULL,
              hash      text,
              label     text,
              held_text text NOT NULL,
              watermark bigint,
              PRIMARY KEY (domain, ordinal)
            )
          SQL

          # Every frozen text version, archived where an edit cannot reach it.
          ERA_TEXTS_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS hecks_era_texts (
              domain      text NOT NULL,
              ordinal     int  NOT NULL,
              digest      text NOT NULL,
              held_text   text NOT NULL,
              archived_at timestamptz NOT NULL DEFAULT now(),
              PRIMARY KEY (domain, ordinal, digest)
            )
          SQL

          # The Layer-3 approvals of translation edges.
          APPROVALS_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS hecks_approvals (
              domain           text NOT NULL,
              from_label       text NOT NULL,
              to_label         text NOT NULL,
              edge_digest      text NOT NULL,
              reviewed_ordinal bigint NOT NULL,
              approved_at      timestamptz NOT NULL DEFAULT now()
            )
          SQL

          # An owned sequence default, not generated always as identity, which
          # partitioned tables only support from Postgres 17.
          JOURNAL_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS %<journal>s (
              ordinal      bigint NOT NULL DEFAULT nextval('%<sequence>s'),
              era          int    NOT NULL,
              aggregate    text   NOT NULL,
              aggregate_id text   NOT NULL,
              operation    text   NOT NULL DEFAULT 'save',
              state        jsonb,
              mirrors      jsonb
            ) PARTITION BY LIST (era)
          SQL

          # One era's partition, built apart from the journal before it is attached.
          PARTITION_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS %<partition>s (
              LIKE %<journal>s INCLUDING DEFAULTS
            )
          SQL

          # Attaches a built partition to the journal.
          ATTACH_PARTITION_SQL = <<~SQL.freeze
            ALTER TABLE %<journal>s
              ATTACH PARTITION %<partition>s FOR VALUES IN (%<era>s)
          SQL
        end
      end
    end
  end
end
