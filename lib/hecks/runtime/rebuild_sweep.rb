module Hecks
  module Runtime
    # THE OUT-OF-BAND HALF OF `projects` (S12, ADR 0025 — "Consistency
    # across aggregate boundaries"). A projected field is never written
    # by the command that reads it — nothing at dispatch time takes a
    # live cross-aggregate read the way `CommandRules::References
    # #dereference` still does — so this is the one place a projected
    # field's value actually gets copied over: walk every record of the
    # OWNING aggregate, resolve each of its own `projected_fields`
    # through the reference it names, and `save` the local copy.
    #
    # EXPLICIT AND CALLABLE, NOT AUTOMATIC — no on-boot detection of a
    # freshly-declared `projects` with no held-era precedent, no
    # generated `Policy#for_each` reaction keeping it live in real
    # time as the target changes. Both are real extensions this same
    # ADR section describes; both are deliberately deferred. This is
    # the mechanism a caller reaches for by hand — `bin/rebuild
    # Domain::Aggregate`, a scheduled job, whatever the deployment
    # needs — proven to work end to end before either automatic
    # trigger is built on top of it.
    #
    # NEEDS NO NEW ADAPTER CAPABILITY. `find`/`all`/`save` are the same
    # three primitives every real adapter already answers identically
    # (`Ports::Persistence::AppendOnly#save` — append, then project,
    # the same for Memory/Postgres/SQLite/D1/Heki) — confirmed by
    # direct reading before this was built, not assumed.
    module RebuildSweep
      module_function

      # One aggregate's own projected fields, refreshed across every
      # record it holds. Returns how many records actually changed —
      # `save` only runs when a projected value would differ from what
      # is already stored, so re-running a sweep with nothing having
      # moved on the target side touches the append log not at all.
      def call(registry, domain, aggregate)
        return 0 if aggregate.projected_fields.empty?

        repository = registry.repository(domain, aggregate)
        repository.all.count { |record| refresh(registry, domain, aggregate, record, repository) }
      end

      def refresh(registry, domain, aggregate, record, repository)
        changed = false

        aggregate.projected_fields.each do |field|
          value = remote_value(registry, domain, aggregate, record, field)
          next if value.nil?
          next if record.key?(field.name) && record[field.name] == value

          record[field.name] = value
          changed = true
        end

        repository.save(record) if changed
        changed
      end

      # `nil` when the reference itself does not resolve in this
      # chapter (a cross-domain target left "unfollowed" the same way
      # References#dereference already leaves one) or when the record
      # names no target at all — an optional reference nobody set.
      def remote_value(registry, domain, aggregate, record, field)
        target = aggregate.attribute(field.reference)&.type&.resolve
        return nil unless target

        id = record[field.reference]
        return nil if id.nil?

        remote = registry.repository(domain, target).find(id.to_s)
        remote&.[](field.remote_field)
      end
    end
  end
end
