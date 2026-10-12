# frozen_string_literal: true

module Hecks
  module Adapters
    module Rehearsal
      # What a `PostgresStore` reads from its database: the eras it holds and the mint's audit over
      # the records under them. No table is provisioned and no era written; a copy somebody else
      # made is read in a read-only session, and the database a run made is its own to touch.
      module PostgresReading
        # @param subject [Subject] the loaded domain
        # @return [Array<Hash>] the eras the database holds, none when it holds no lineage
        def eras(subject)
          reading(subject) { |lineage| subject.held.held_eras(lineage) }
        end

        # @param subject [Subject] the loaded domain
        # @param _edge [Bluebook::Translation] the edge leading to the shape
        # @return [Array(Array<String>, Hash)] what the audit's layers refuse over the stored
        #   records, and the records as translated, by aggregate name and id
        def audit(subject, _edge)
          reading(subject) do |lineage|
            finding = JournalStore::EdgeAudit.call(subject.held, lineage, subject.held.held_eras(lineage))
            finding ? [finding.refusals, finding.after] : [[], {}]
          end
        end

        # @param _edge [Bluebook::Translation] unused
        # @return [Array<Hash>] none: a postgres copy runs the compiled rules itself
        def limits(_edge) = []

        private

        def reading(subject)
          subject.held.read_from(url)
          db = PostgresEra.connect_for(subject.bluebook.name, subject.held.settings)
          db.exec("SET default_transaction_read_only = on") if @declaration.mode == "readonly_copy"
          yield PostgresEra::Lineage.new(db, subject.bluebook.name)
        ensure
          db&.close
        end
      end
    end
  end
end
