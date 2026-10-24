module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The SQL templates of the head and its chain, filled with `format`.
        module SqlTemplates
          # The DDL for one era's head-snapshot table. A delete upserts a tombstone
          # (operation = 'delete', state NULL) instead of removing the row, so it still
          # outranks a stale ancestor `save` row by ordinal under DISTINCT ON.
          HEAD_SNAPSHOT_SQL = <<~SQL.freeze
            CREATE TABLE %<table>s (
              id        text PRIMARY KEY,
              ordinal   bigint NOT NULL,
              operation text NOT NULL DEFAULT 'save',
              state     jsonb
            )
          SQL

          # One chunk of the journal's latest save per id, after `cursor` when the backfill resumes.
          HEAD_BACKFILL_SQL = <<~SQL.freeze
            SELECT id, ordinal, state FROM (
              SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, ordinal, operation, state
              FROM %<journal>s
              WHERE era = %<era>s AND aggregate = %<aggregate>s
              %<after_cursor>s
              ORDER BY aggregate_id, ordinal DESC
            ) latest WHERE operation = 'save' ORDER BY id LIMIT %<chunk_size>s
          SQL

          # Era 1's head view: the snapshot table itself. WHERE operation = 'save' excludes
          # delete tombstones, whose state is NULL, so a deleted id falls out of the head
          # instead of resolving to a nil state.
          FIRST_HEAD_VIEW_SQL = <<~SQL.freeze
            CREATE OR REPLACE VIEW %<head_view>s AS
            SELECT id, state FROM %<snapshot>s WHERE operation = 'save'
          SQL

          # The head view of era N: the era's matview merged with its own snapshot. Reads the
          # snapshot's own operation column rather than hardcoding 'save', so a tombstone here
          # outranks a stale ancestor save row by ordinal instead of letting it resurrect a
          # deleted record.
          HEAD_VIEW_SQL = <<~SQL.freeze
            CREATE VIEW %<head_view>s AS
            SELECT id, state FROM (
              SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state FROM (
                SELECT ordinal, aggregate_id, operation, state FROM %<view>s
                UNION ALL
                SELECT ordinal, id AS aggregate_id, operation, state
                FROM %<snapshot>s
              ) merged ORDER BY aggregate_id, ordinal DESC
            ) latest WHERE operation = 'save'
          SQL

          # Era N layered onto era N-1's existing matview.
          LAYERED_SQL = <<~SQL.freeze
            WITH layered AS (
              SELECT DISTINCT ON (aggregate_id) ordinal, aggregate_id, operation, state FROM (
                SELECT ordinal, aggregate_id, operation, state FROM %<prior_view>s
                UNION ALL
                SELECT ordinal, aggregate_id, operation, state FROM %<journal>s
                WHERE era = %<prior_era>s AND aggregate = %<aggregate>s%<cut>s
              ) layers ORDER BY aggregate_id, ordinal DESC
            )
            SELECT ordinal, %<id_column>s, operation,
                   CASE WHEN operation = 'save' THEN %<expression>s ELSE state END AS state
            FROM layered
          SQL

          # Every edge chained over the reduced ancestor tail.
          CHAIN_SQL = <<~SQL.freeze
            WITH tail AS (%<tail>s),
            %<chain>s
            SELECT ordinal, aggregate_id, operation, state FROM edge_%<last>s
          SQL

          # Reduces to newest entry per aggregate id, dropping any id whose newest entry is a
          # delete.
          LATEST_SQL = <<~SQL.freeze
            SELECT aggregate_id, state FROM (
              SELECT DISTINCT ON (aggregate_id) aggregate_id, operation, state
              FROM (%<sql>s) chained ORDER BY aggregate_id, ordinal DESC
            ) latest WHERE operation = 'save'
          SQL
        end
      end
    end
  end
end
