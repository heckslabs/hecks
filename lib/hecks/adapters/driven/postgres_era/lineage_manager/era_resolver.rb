require_relative "../lineage"
require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "context"
require_relative "mint_request"
require_relative "mint_decision"
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

          # Opens the lineage: for reading on a boot, and provisioned first on a mint request.
          def open_lineage(db, bluebook, settings, request)
            lineage = Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as,
                                                     reading:           request.nil?)
            # First, before anything else: the earliest point the connection's role is known,
            # so a superuser connection refuses here by default.
            lineage.check_fence_applies!(allow_superuser: PostgresEra.setting(settings, :allow_superuser, default: false))
            lineage.ensure_base! if request
            lineage
          end

          # Whether the world allows minting, spelled as a boolean or as the word.
          def mint_permitted?(settings)
            [true, "true"].include?(PostgresEra.setting(settings, :mint_eras, default: MINT_BY_DEFAULT))
          end

          def resolve_era(context)
            held = context.held_eras
            return refuse_unheld!(context) if held.empty?

            resolve_held(context, held)
          end

          # No era is held: the first era is held by the mint entry point, never by a boot.
          def refuse_unheld!(context)
            raise Runtime::WiringError,
                  "cannot boot #{context.domain_name}: no era held; run the mint entry point " \
                  "(`hecks hold_first <domain directory> --confirm`) to hold the first era"
          end

          # Some era is held: the latest, a superseded one, or none matches and a new one is minted.
          def resolve_held(context, held)
            shapes = held_shapes(context.bluebook, held)
            latest, latest_shape = shapes.last
            current_shape = context.current_shape
            return resolve_latest(context, latest) if latest_shape == current_shape

            matched, = shapes.find { |_, shape| shape == current_shape }
            return resolve_superseded(context, matched, latest) if matched

            return resolve_unminted(context, latest) unless context.mint_request

            context.record_resolved(mint!(context.with(latest: latest)))
          end

          # A shape no held era matches, booted without a mint request: the copy reads the latest
          # held era and writes nothing. When a recorded move or a translation edge leads the latest
          # era to this shape, the boot reports it as behind; a mint would cover it, and the mint
          # entry point runs that mint.
          def resolve_unminted(context, latest)
            context.record_resolved(latest[:ordinal])
            context.record_unminted(latest[:ordinal])
            context.record_behind(latest[:ordinal]) if behind?(context, latest)
            nil
          end

          # Whether a mint from the latest held era would go ahead on its edge or recorded move.
          # Reads only: the decision takes the loaded translations and the recorded moves.
          def behind?(context, latest)
            verdict = MintDecision.decide_latest(
              latest, bluebook: context.bluebook, translations: context.translations,
                      directory: context.directory, watermark: context.watermark
            )
            verdict.verdict == "would_mint"
          end

          # The latest held era is the current shape: nothing to mint, nothing to write.
          def resolve_latest(context, latest)
            context.record_resolved(latest[:ordinal])
            nil
          end

          # A superseded era (an old checkout) reads and never writes: the fence is already past
          # this ordinal, so nothing here advances it.
          def resolve_superseded(context, matched, latest)
            context.record_resolved(matched[:ordinal])
            # The adapter refuses appends on this, even where the RLS fence cannot bind.
            context.record_superseded(latest[:ordinal])
            nil
          end

          # Each held era with its storage shape. Held text is a frozen record and keeps the
          # prior name; only the in-memory shape is normalized, and only on an exact match with
          # the declared prior name.
          def held_shapes(bluebook, held)
            shapes = held.map { |era| [era, held_shape(era)] }
            return shapes unless bluebook.formerly_known_as

            shapes.map do |era, shape|
              [era, shape["name"] == bluebook.formerly_known_as ? shape.merge("name" => bluebook.name) : shape]
            end
          end

          # The storage shape an era holds: the projection its mint recorded, which covers every
          # file of a domain split across files. The held text is the root file only, so an era
          # minted without a projection falls back to the shape that text declares.
          def held_shape(era)
            era[:projection] || Runtime::StorageShape.project(shadow(era[:held_text]))
          end
        end
      end
    end
  end
end
