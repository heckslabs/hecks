require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "mint_decision"
require_relative "../lineage"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The one answer to which era a bluebook's shape resolves to, given the eras its database
        # holds: the boot records it, the boot status reports it, and the rehearsal and the mint
        # read the held era and the match from it. It writes nothing. A status is one of:
        #
        # - `unheld`: the database holds no era for the bluebook.
        # - `current`: the latest held era holds the current shape.
        # - `superseded`: an older held era holds the current shape; a later one superseded it.
        # - `behind`: no era holds the current shape, and a mint from the latest one would go ahead
        #   on its translation edge or recorded implicit move.
        # - `unminted`: no era holds the current shape, and no mint from the latest one would go
        #   ahead.
        module EraResolution
          # What a resolution concludes. `resolved` is the era the boot reads (nil when `unheld`),
          # `latest` the latest held era, `verdict` the mint decision from the latest era (nil
          # unless the shape is `behind` or `unminted`), and `held_count` how many eras are held.
          Answer = Data.define(:status, :resolved, :latest, :current_label, :verdict, :held_count) do
            # @return [Boolean] whether a held era holds the current shape
            def matched? = %w[current superseded].include?(status)

            # The label of the era the boot reads. An era no edge has left yet has no stored name,
            # so its label is worked out in memory, as its mint would name it; naming is a write,
            # so a resolution never stores it.
            #
            # @return [String, nil] the label; nil when no era is held
            # @raise [Runtime::WiringError] when an unnamed era stores no shape (`refuse_unshaped!`)
            def held_label
              stored = resolved&.fetch(:label, nil)
              return stored if stored || resolved.nil?

              LineageManager.held_hash(resolved)[0, Runtime::StorageShape::LABEL_LENGTH]
            end

            # @return [Integer, nil] the ordinal of the era the boot reads
            def ordinal = resolved&.fetch(:ordinal, nil)

            # @return [String, nil] why the status is what it is; nil for `current`
            def reason = Reasons.of(self)

            # @return [Boolean] whether a mint from the latest era would go ahead on a recorded
            #   implicit move rather than a written translation edge
            def implicit? = verdict&.source == "implicit"

            # @return [String] the mint decision from the latest era and why, as `verdict: reason`
            def decision = "#{verdict.verdict}: #{verdict.reason}"

            # @return [Hash, nil] the implicit move a `behind` shape would mint on, or nil
            def move
              return unless status == "behind" && implicit?

              { "from" => held_label, "to" => current_label }
            end

            # @return [Hash] the answer as a status row, string-keyed for a JSON document
            def to_row
              { "status" => status, "held" => held_label, "current" => current_label, "ordinal" => ordinal,
                "move" => move, "reason" => reason, "source" => "database" }
            end
          end

          module_function

          # Resolves the current shape of a bluebook against the eras its database holds.
          #
          # @param eras [Array<Hash>] the held eras, oldest first, as `Lineage#eras` answers them
          # @param bluebook [Bluebook::Declaration] the bluebook as it stands
          # @param translations [Array<Object>] the translation edges the registry loaded
          # @param directory [String, nil] the domain's bluebook directory, where moves are recorded
          # @yieldreturn [Integer] the ledger watermark, read only when no held era matches
          # @return [Answer]
          def resolve(eras:, bluebook:, translations:, directory:)
            facts = { latest: eras.last, current_label: MintDecision.label_of(bluebook), held_count: eras.size }
            return answer("unheld", nil, facts) if eras.empty?

            matched = matching_era(eras, bluebook)
            return answer(matched.equal?(eras.last) ? "current" : "superseded", matched, facts) if matched

            unmatched(facts, bluebook, translations, directory, yield)
          end

          # Resolves a bluebook against the eras its own database holds, over a connection that
          # can only read: nothing is provisioned, and the session refuses any write.
          #
          # @param bluebook [Bluebook::Declaration] the bluebook as it stands
          # @param settings [Hash] the persistence settings its world declares; needs `database`
          # @param translations [Array<Object>] the translation edges the registry loaded
          # @param directory [String, nil] the domain's bluebook directory
          # @return [Answer]
          # @raise [Runtime::WiringError] if the connection is refused or a held text fails its
          #   integrity check
          def read(bluebook:, settings:, translations:, directory: nil)
            db = PostgresEra.connect_for(bluebook.name, settings, provision: false)
            db.exec("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
            lineage = Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as, reading: true)
            resolve(eras: lineage.eras, bluebook: bluebook, translations: translations, directory: directory) do
              lineage.last_ordinal
            end
          ensure
            db&.close
          end

          # The held era whose shape is the bluebook's: the latest when it holds it, else the
          # oldest that does; nil when none holds it.
          #
          # @param eras [Array<Hash>] the held eras, oldest first
          # @param bluebook [Bluebook::Declaration] the bluebook as it stands
          # @return [Hash, nil] the matching era
          def matching_era(eras, bluebook)
            current = Runtime::StorageShape.project(bluebook)
            [eras.last, *eras].find { |era| held_shape_of(era, bluebook) == current }
          end

          # An era's storage shape, with a prior name normalized to the bluebook's. Held text is a
          # frozen record and keeps the prior name; only the in-memory shape is renamed, and only on
          # an exact match with the declared prior name.
          #
          # @param era [Hash] a held era
          # @param bluebook [Bluebook::Declaration] the bluebook as it stands
          # @return [Hash] the storage shape the era holds
          def held_shape_of(era, bluebook)
            shape = LineageManager.held_shape(era)
            prior = bluebook.formerly_known_as
            prior && shape["name"] == prior ? shape.merge("name" => bluebook.name) : shape
          end

          # @return [Answer] a `behind` or `unminted` answer, by the latest era's mint decision
          def unmatched(facts, bluebook, translations, directory, watermark)
            verdict = MintDecision.decide_latest(facts[:latest], bluebook: bluebook, translations: translations,
                                                                 directory: directory, watermark: watermark)
            answer(verdict.verdict == "would_mint" ? "behind" : "unminted", facts[:latest], facts, verdict)
          end

          # @return [Answer]
          def answer(status, resolved, facts, verdict = nil)
            Answer.new(status: status, resolved: resolved, verdict: verdict, **facts)
          end

          # The sentence a status row gives for its status.
          module Reasons
            module_function

            # @param answer [Answer] the resolution
            # @return [String, nil] the reason; nil for `current`
            def of(answer)
              case answer.status
              when "unheld" then "no era is held; the mint entry point holds the first"
              when "superseded" then superseded(answer)
              when "behind" then behind(answer)
              when "unminted" then unminted(answer)
              end
            end

            # @return [String]
            def superseded(answer)
              "era #{answer.ordinal} holds the current shape #{answer.current_label}; era " \
                "#{answer.latest[:ordinal]} (#{answer.latest[:label]}) superseded it"
            end

            # @return [String]
            def behind(answer)
              "no era holds #{answer.current_label}; a mint from era #{answer.ordinal} (#{answer.held_label}) " \
                "would go ahead on its #{answer.implicit? ? "recorded implicit move" : "translation edge"}"
            end

            # @return [String]
            def unminted(answer)
              "no era holds #{answer.current_label}; a mint from era #{answer.ordinal} (#{answer.held_label}) " \
                "is #{answer.decision}"
            end
          end
        end
      end
    end
  end
end
