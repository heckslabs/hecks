require_relative "../lineage"
require_relative "../../storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Boot-time era resolution: first boot holds era 1, a quiet reboot changes nothing,
        # a superseded shape boots read-only, an unheld shape goes to the minter.
        module EraResolver
          # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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
            role = settings.key?(:role) ? settings[:role] : settings["role"]

            held = lineage.eras
            if held.empty?
              lineage.hold_first!(current_text, projection: Runtime::StorageShape.project(bluebook))
              bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) }
              lineage.grant_role!(role, aggregates: bluebook.aggregates, era: 1) if role
              return
            end

            current_shape = Runtime::StorageShape.project(bluebook)
            shapes = held.map { |era| [era, Runtime::StorageShape.project(shadow(era[:held_text]))] }
            if bluebook.formerly_known_as
              # Held text is frozen record and keeps the prior name; only the in-memory shape is
              # normalized, and only on an exact match with the declared prior name.
              shapes = shapes.map do |era, shape|
                [era, shape["name"] == bluebook.formerly_known_as ? shape.merge("name" => bluebook.name) : shape]
              end
            end

            latest, latest_shape = shapes.last
            if latest_shape == current_shape
              bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) } if latest[:ordinal] == 1
              lineage.grant_role!(role, aggregates: bluebook.aggregates, era: latest[:ordinal]) if role
              registry.resolved_eras[bluebook.name] = latest[:ordinal]
              return
            end

            matched, = shapes.find { |_, shape| shape == current_shape }
            if matched
              # A superseded era (an old checkout) may read but not write: never advance_era!
              # here, since the fence is already past this ordinal.
              lineage.grant_role!(role, aggregates: bluebook.aggregates, era: matched[:ordinal]) if role
              registry.resolved_eras[bluebook.name] = matched[:ordinal]
              # The adapter refuses appends on this, even where the RLS fence cannot bind.
              registry.superseded_eras[bluebook.name] = latest[:ordinal]
              return
            end

            registry.resolved_eras[bluebook.name] =
              mint!(registry, bluebook, current_text, lineage, latest,
                    role: role, directory: directory)
          ensure
            db&.close
          end
          # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        end
      end
    end
  end
end
