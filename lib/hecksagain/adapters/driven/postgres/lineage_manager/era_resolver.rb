module Hecksagain
  module Adapters
    class Postgres
      module LineageManager
        # The boot-time resolution: which era IS this checkout? First
        # boot holds era 1; a quiet reboot changes nothing; a
        # held-but-superseded shape boots read-only-toward-the-fence; an
        # unheld shape goes to the minter.
        module EraResolver
          def check!(registry:, bluebook:, current_text:, settings:, directory: nil)
            db = Postgres.connect_for(bluebook.name, settings)
            lineage = Lineage.new(db, bluebook.name)
            lineage.ensure_base!
            role = settings[:role] || settings["role"]

            held = lineage.eras
            if held.empty?
              lineage.hold_first!(current_text, projection: Runtime::StorageShape.project(bluebook))
              bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) }
              # hold_first! already established era 1 as current for
              # EVERY role; this one just needs its own privileges.
              lineage.grant_role!(role) if role
              return
            end

            current_shape = Runtime::StorageShape.project(bluebook)
            shapes = held.map { |era| [era, Runtime::StorageShape.project(shadow(era[:held_text]))] }

            latest, latest_shape = shapes.last
            if latest_shape == current_shape
              bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) } if latest[:ordinal] == 1
              # A quiet reboot changes no era, so there is nothing to
              # advance — only this role's own privileges, if it is new.
              lineage.grant_role!(role) if role
              registry.resolved_eras[bluebook.name] = latest[:ordinal]
              return
            end

            matched, = shapes.find { |_, shape| shape == current_shape }
            if matched
              # A held-but-superseded era — an old checkout still running.
              # It may keep BOOTING and READING (Postgres is the one
              # adapter that recognizes this rather than refusing), but it
              # may not keep WRITING: the shared era fence was already
              # advanced past this ordinal by whichever mint superseded
              # it, and nothing here may roll that back. Granting only
              # this role's privileges, never advance_era!, is what keeps
              # that true — see advance_era!'s own warning against being
              # called with a superseded ordinal.
              lineage.grant_role!(role) if role
              registry.resolved_eras[bluebook.name] = matched[:ordinal]
              return
            end

            registry.resolved_eras[bluebook.name] =
              mint!(registry, bluebook, current_text, lineage, latest,
                    role: role, directory: directory)
          ensure
            db&.close
          end
        end
      end
    end
  end
end
