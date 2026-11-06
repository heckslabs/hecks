# frozen_string_literal: true

require_relative "postgres_census"

module Hecks
  module Adapters
    module Rehearsal
      # What a `PostgresStore` reads from its database: the eras it holds and the mint's audit over
      # the records under them. No table is provisioned and no era written; a copy somebody else
      # made is read in a read-only session, and the database a run made is its own to touch.
      #
      # The schema is the world's `schema`, else `HECKS_SCHEMA`, else the one the domain's name
      # gives (`Shop` is `shop`), else `public` when that holds the lineage. It is looked up
      # before it is used, so a schema the copy does not have is reported and never created.
      module PostgresReading
        # @param subject [Subject] the loaded domain
        # @return [Census] what the copy holds for the domain, counted once
        def census(subject)
          @census ||= PostgresCensus.new(url, subject, schema_candidates(subject)).read.tap do |found|
            subject.held.read_schema(found.schema)
          end
        end

        # @param subject [Subject] the loaded domain
        # @return [Array<Hash>] the eras the database holds, none when it holds no lineage
        def eras(subject)
          return [] unless census(subject).present

          reading(subject) { |lineage| subject.held.held_eras(lineage) }
        end

        # @param subject [Subject] the loaded domain
        # @return [Integer] the ledger watermark the copy holds: zero when it holds no lineage
        def watermark(subject)
          return 0 unless census(subject).present

          reading(subject, &:last_ordinal)
        end

        # @param subject [Subject] the loaded domain
        # @param subject [Subject] the loaded domain
        # @param edge [Object] the edge `Subject#decide` named for the shape, the one the mint takes
        # @return [Array(Array<String>, Hash)] what the audit's layers refuse over the stored
        #   records, and the records as translated, by aggregate name and id
        def audit(subject, edge)
          return [[], {}] unless census(subject).present

          reading(subject) do |lineage|
            finding = JournalStore::EdgeAudit.call(subject.held, lineage, subject.held.held_eras(lineage), edge: edge)
            finding ? [finding.refusals, finding.after] : [[], {}]
          end
        end

        private

        def schema_candidates(subject)
          return [[@declaration.schema, "world"]] if @declaration.schema
          return [[ENV.fetch("HECKS_SCHEMA"), "HECKS_SCHEMA"]] if ENV.fetch("HECKS_SCHEMA", "") != ""

          [[Naming.snake(subject.bluebook_name), "derived"], %w[public default]]
        end

        def reading(subject)
          subject.held.read_from(url)
          db = connect(subject)
          yield PostgresRevisions::Lineage.new(db, subject.bluebook_name, reading: reads_only?)
        ensure
          db&.close
        end

        # A copy somebody else made is opened read-only before any statement runs: the schema is
        # selected, never created, and a digest the copy lacks is left unwritten. A database the run
        # made is its own to touch, so it is opened as a PostgresRevisions boot opens it.
        def connect(subject)
          return PostgresRevisions.connect_for(subject.bluebook_name, subject.settings) unless reads_only?

          require "pg"
          PG.connect(url).tap do |db|
            db.exec("SET default_transaction_read_only = on")
            db.exec("SET search_path TO #{db.quote_ident(subject.settings[:schema])}") if subject.settings[:schema]
          end
        end

        def reads_only? = @declaration.mode == "readonly_copy"
      end
    end
  end
end
