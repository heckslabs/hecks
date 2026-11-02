require_relative "../lineage"
require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "context"
require_relative "mint_request"
require_relative "mint_decision"
require_relative "era_resolution"
require_relative "disposable_ledger"
require_relative "../../../../indifferent_key"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Boot-time era resolution. A boot reads: it reports the era its shape resolves to, and
        # writes nothing. The mint entry point (a settings `mint_request`) is the only path that
        # provisions the lineage or mints an era.
        module EraResolver
          # Whether this copy may mint when its world says nothing about it. False, so a copy that
          # was not told refuses, and only the copy that owns a database moves it. A mint also needs
          # the mint entry point's request (`mint_request` in the settings): a boot never mints.
          MINT_BY_DEFAULT = false

          # Resolves which era this boot is and records it on the registry.
          #
          # A boot with no mint request opens its lineage for reading and never provisions, holds,
          # mints or grants. A boot with a request provisions the lineage first, then mints if the
          # shape drifted.
          #
          # @return [Integer, nil] the ordinal minted, or nil when this boot minted nothing
          # @raise [Runtime::WiringError] if the connection is refused, a held text fails its
          #   integrity check, no era is held, or the shape is unheld and `mint!` refuses
          def check!(registry:, bluebook:, current_text:, settings:, directory: nil)
            # A world that declares its ledger disposable has no era guard: see `DisposableLedger`.
            return DisposableLedger.check!(registry:, bluebook:, current_text:, settings:) if DisposableLedger.declared?(settings)

            request = MintRequest.from(settings)
            db = PostgresEra.connect_for(bluebook.name, settings, provision: !request.nil?)
            lineage = open_lineage(db, bluebook, settings, request)
            resolve_era(Context.new(registry: registry, bluebook: bluebook, current_text: current_text,
                                    lineage: lineage, role: IndifferentKey.read(settings, :role),
                                    directory: directory, mint_permitted: mint_permitted?(settings),
                                    mint_request: request))
          ensure
            db&.close
          end

          private

          # Opens the lineage: for reading on a boot, and provisioned first on a mint request. Either
          # refuses, by name, while the domain's history still sits under its former name.
          def open_lineage(db, bluebook, settings, request)
            lineage = Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as,
                                                     reading:           request.nil?)
            # First, before anything else: the earliest point the connection's role is known,
            # so a superuser connection refuses here by default.
            lineage.check_fence_applies!(allow_superuser: PostgresEra.setting(settings, :allow_superuser, default: false))
            request ? lineage.ensure_base! : lineage.refuse_pending_rename!
            lineage
          end

          # Whether the world allows minting, spelled as a boolean or as the word.
          def mint_permitted?(settings)
            [true, "true"].include?(PostgresEra.setting(settings, :mint_eras, default: MINT_BY_DEFAULT))
          end

          # Resolves the boot's shape through `EraResolution`, the answer every era tool reads, and
          # records it on the registry; a mint request on a shape no era holds mints instead.
          def resolve_era(context)
            answer = EraResolution.resolve(eras: context.held_eras, bluebook: context.bluebook,
                                           translations: context.translations, directory: context.directory) do
              context.watermark
            end
            return refuse_unheld!(context) if answer.status == "unheld"
            return context.record_resolved(mint!(context.with(latest: answer.latest))) if minting?(answer, context)

            return refuse_breaking!(context, answer) if answer.breaking?

            record(context, answer)
          end

          # A breaking move no edge covers: the boot reads nothing and writes nothing. This stands
          # in until the commit-time gate (ADR 0168) keeps such a move off main.
          def refuse_breaking!(context, answer)
            raise Runtime::WiringError, "cannot boot #{context.domain_name}: #{answer.reason}"
          end

          # Whether this check mints: a mint request, on a shape no held era holds.
          def minting?(answer, context) = context.mint_request && !answer.matched?

          # No era is held: the first era is held by the mint entry point, never by a boot.
          def refuse_unheld!(context)
            raise Runtime::WiringError,
                  "cannot boot #{context.domain_name}: no era held; run the mint entry point " \
                  "(`hecks hold_first <domain directory> --confirm`) to hold the first era"
          end

          # Records what the resolution answered and writes nothing. A superseded era (an old
          # checkout) reads and never writes: the adapter refuses appends on it, even where the RLS
          # fence cannot bind. A shape no era holds reads the latest held era, and is behind when a
          # mint from it would go ahead; the mint entry point runs that mint.
          def record(context, answer)
            context.record_resolved(answer.ordinal)
            latest = answer.latest[:ordinal]
            status = answer.status
            context.record_superseded(latest) if status == "superseded"
            context.record_unminted(latest) if %w[unminted behind].include?(status)
            context.record_behind(latest) if status == "behind"
            nil
          end
        end
      end
    end
  end
end
