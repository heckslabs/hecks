require_relative "../lineage"
require_relative "../../storage_shape"
require_relative "context"
require_relative "../../../../../../indifferent_key"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Boot-time era resolution: first boot holds era 1, a quiet reboot changes nothing,
        # a superseded shape boots read-only, an unheld shape goes to the minter.
        module EraResolver
          # Resolves which era this boot is and records it on the registry.
          #
          # @return [Integer, nil] the ordinal minted, or nil when this boot minted nothing
          # @raise [Runtime::WiringError] if the connection is refused, a held text fails its
          #   integrity check, or the shape is unheld and `mint!` refuses
          def check!(registry:, bluebook:, current_text:, settings:, directory: nil)
            db = PostgresEra.connect_for(bluebook.name, settings)
            lineage = Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
            # First, before ensure_base!: the earliest point the connection's role is known,
            # so a superuser connection refuses here by default.
            lineage.check_fence_applies!(allow_superuser: PostgresEra.setting(settings, :allow_superuser, default: false))
            lineage.ensure_base!
            # key? first, never `||`: a stored `false` must not read as an absent key.
            role = IndifferentKey.read(settings, :role)
            resolve_era(Context.new(registry: registry, bluebook: bluebook, current_text: current_text,
                                    lineage: lineage, role: role, directory: directory))
          ensure
            db&.close
          end

          private

          def resolve_era(context)
            held = context.lineage.eras
            return hold_first_era(context) if held.empty?

            shapes = held_shapes(context.bluebook, held)
            latest, latest_shape = shapes.last
            current_shape = context.current_shape
            return resolve_latest(context, latest) if latest_shape == current_shape

            matched, = shapes.find { |_, shape| shape == current_shape }
            return resolve_superseded(context, matched, latest) if matched

            context.record_resolved(mint!(context.with(latest: latest)))
          end

          def hold_first_era(context)
            context.lineage.hold_first!(context.current_text, projection: context.current_shape)
            ensure_first_heads!(context)
            grant_role!(context, 1)
            nil
          end

          # The latest held era is the current shape: nothing to mint.
          def resolve_latest(context, latest)
            ensure_first_heads!(context) if latest[:ordinal] == 1
            grant_role!(context, latest[:ordinal])
            context.record_resolved(latest[:ordinal])
            nil
          end

          # A superseded era (an old checkout) may read but not write: never advance_era!
          # here, since the fence is already past this ordinal.
          def resolve_superseded(context, matched, latest)
            grant_role!(context, matched[:ordinal])
            context.record_resolved(matched[:ordinal])
            # The adapter refuses appends on this, even where the RLS fence cannot bind.
            context.record_superseded(latest[:ordinal])
            nil
          end

          def ensure_first_heads!(context)
            context.bluebook.aggregates.each { |aggregate| context.lineage.ensure_first_head!(aggregate.storage_name) }
          end

          def grant_role!(context, ordinal)
            return unless context.role

            context.lineage.grant_role!(context.role, aggregates: context.bluebook.aggregates, era: ordinal)
          end

          # Each held era with its storage shape. Held text is a frozen record and keeps the
          # prior name; only the in-memory shape is normalized, and only on an exact match with
          # the declared prior name.
          def held_shapes(bluebook, held)
            shapes = held.map { |era| [era, Runtime::StorageShape.project(shadow(era[:held_text]))] }
            return shapes unless bluebook.formerly_known_as

            shapes.map do |era, shape|
              [era, shape["name"] == bluebook.formerly_known_as ? shape.merge("name" => bluebook.name) : shape]
            end
          end
        end
      end
    end
  end
end
