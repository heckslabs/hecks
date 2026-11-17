# frozen_string_literal: true

require "digest"
require "fileutils"

module Hecks
  module Adapters
    class RecordIndex
      # A SQLite FTS5 table of records, brought up to date by upserting only what changed, and
      # searched by BM25 rank. It holds no model and no embedding.
      class Store
        # A word of a search: letters, digits and underscores, so FTS5 syntax is never read.
        WORD = /[[:alnum:]_]+/

        # @param path [String] the SQLite file, or ":memory:"
        def initialize(path)
          require "sqlite3"
          FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
          @db = SQLite3::Database.new(path)
          @db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS records USING fts5(kind UNINDEXED, id UNINDEXED, body)")
          @db.execute("CREATE TABLE IF NOT EXISTS digests (kind TEXT, id TEXT, digest TEXT, PRIMARY KEY (kind, id))")
        end

        # Adds, replaces and drops rows so the index holds exactly `records`; an unchanged row is
        # not touched.
        #
        # @param records [Array<Array(String, String, String)>] kind, id and text of each record
        def sync(records)
          @db.transaction do
            held = @db.execute("SELECT kind, id, digest FROM digests").to_h { |kind, id, digest| [[kind, id], digest] }
            records.each { |record| upsert(record, held.delete(record.first(2))) }
            held.each_key { |kind, id| drop(kind, id) }
          end
        end

        # @param words [String] the words to look for, all of which a hit holds
        # @param kind [String, nil] narrows the hits to one kind
        # @param top [Integer] the most hits returned
        # @return [Array<Array(String, String, String)>] kind, id and one-line snippet, best first
        def search(words, kind: nil, top: 10)
          terms = words.scan(WORD).map { |term| %("#{term}") }
          return [] if terms.empty?

          @db.execute(query(kind), [terms.join(" "), *kind, top])
        end

        private

        def query(kind)
          "SELECT kind, id, replace(snippet(records, 2, '', '', '...', 12), char(10), ' ') FROM records " \
            "WHERE records MATCH ? #{"AND kind = ?" if kind} ORDER BY bm25(records) LIMIT ?"
        end

        def upsert((kind, id, text), digest)
          fresh = Digest::SHA1.hexdigest(text)
          return if digest == fresh

          drop(kind, id) if digest
          @db.execute("INSERT INTO records (kind, id, body) VALUES (?, ?, ?)", [kind, id, text])
          @db.execute("INSERT INTO digests VALUES (?, ?, ?)", [kind, id, fresh])
        end

        def drop(kind, id)
          @db.execute("DELETE FROM records WHERE kind = ? AND id = ?", [kind, id])
          @db.execute("DELETE FROM digests WHERE kind = ? AND id = ?", [kind, id])
        end
      end
    end
  end
end
