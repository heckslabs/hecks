module Hecks
  module Fuzzing
    module Properties
      # Property: a command that `references` an aggregate was never accepted against a record
      # nothing in the history created.
      #
      # The dispatch pipeline refuses such a command with NotFound; this reads the accepted
      # ones back, so a dangling reference that got through shows up as an emission with no
      # earlier event for the record it addressed. A replay boots empty, so every record that
      # exists was created by an earlier emission.
      module References
        # Every event a referencing command emitted has an earlier event for the referenced record.
        #
        # An event name that a creating command of the same aggregate also emits is skipped: the
        # name alone cannot say which command produced it. An identity the payload does not carry
        # as a plain scalar is inconclusive, not a violation.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each emission with a dangling reference
        def references_resolve_to_earlier_records(history)
          events = Array(history[:events])

          violations = (history[:bluebooks] || {}).flat_map do |domain, bluebook|
            bluebook.aggregates.flat_map { |aggregate| dangling_references(events, domain, bluebook, aggregate) }
          end
          violations.empty? || violations.uniq.join("; ")
        end

        # Messages for the emissions of `aggregate`'s referencing commands that address no earlier record.
        def dangling_references(events, domain, bluebook, aggregate)
          own = "#{domain}::#{aggregate.hecks_name}"
          creating_events = aggregate.commands.select { |command| command.references.to_s.empty? }.flat_map { |c| c.emits.map(&:to_s) }

          aggregate.commands.reject { |command| command.references.to_s.empty? }.flat_map do |command|
            target = Naming.demodulise(command.references)
            command.emits.map(&:to_s).reject { |name| creating_events.include?(name) }.flat_map do |name|
              events.each_with_index.filter_map do |event, index|
                next unless event[:name] == name && event[:aggregate] == own

                dangling_message(command, event, events.first(index), domain, bluebook, own, target)
              end
            end
          end
        end

        # A message when `event`'s referenced record has no earlier event; nil when one exists or
        # the reference cannot be read off the payload.
        def dangling_message(command, event, preceding, domain, bluebook, own, target)
          key = target_key(domain, bluebook, own, target)
          return unless key

          id = referenced_id(event, target, own, key)
          return if id.nil? || preceding.any? { |earlier| earlier[:aggregate] == key && earlier[:id].to_s == id }

          "#{command.hecks_name} (#{own}##{event[:id]}) was accepted referencing #{key}##{id}, " \
            "but no earlier event created that record"
        end

        # The `"Domain::Aggregate"` key the reference points at; nil when the target is not an
        # aggregate of this domain (a cross-domain reference this property cannot read).
        def target_key(domain, bluebook, own, target)
          return own if own.split("::").last == target

          "#{domain}::#{target}" if bluebook.aggregates.any? { |candidate| candidate.hecks_name == target }
        end

        # The id the emission addressed: the event's own id when the command references its own
        # aggregate, else the reference key's scalar in the payload. nil when not a plain scalar.
        def referenced_id(event, target, own, key)
          return event[:id].to_s if key == own

          value = (event[:payload] || {}).then { |payload| payload[Naming.reference_key(target)] || payload[Naming.reference_key(target).to_s] }
          value = value["value"] || value[:value] if value.is_a?(Hash)
          value.is_a?(String) || value.is_a?(Numeric) ? value.to_s : nil
        end
      end
    end
  end
end
