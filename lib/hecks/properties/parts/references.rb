module Hecks
  module Fuzzing
    module Properties
      # Reads one aggregate's referencing commands against the events of a history.
      #
      # An event name that a creating command of the same aggregate also emits is skipped: the
      # name alone cannot say which command produced it. An identity the payload does not carry
      # as a plain scalar is inconclusive, not a violation.
      class ReferenceReading
        def initialize(domain, bluebook, aggregate, events)
          @domain = domain
          @bluebook = bluebook
          @aggregate = aggregate
          @events = events
          @own = "#{domain}::#{aggregate.hecks_name}"
        end

        # Messages for the emissions of referencing commands that address no earlier record.
        def dangling
          referencing.flat_map { |command| command_dangling(command) }
        end

        private

        def referencing = @aggregate.commands.reject { |command| command.references.to_s.empty? }

        def creating_events
          creating = @aggregate.commands.select { |command| command.references.to_s.empty? }
          creating.flat_map { |command| command.emits.map(&:to_s) }
        end

        def command_dangling(command)
          key = target_key(command)
          return [] unless key

          names = command.emits.map(&:to_s) - creating_events
          @events.each_with_index.filter_map do |event, index|
            next unless names.include?(event[:name]) && event[:aggregate] == @own

            message(command, event, @events.first(index), key)
          end
        end

        def message(command, event, preceding, key)
          id = referenced_id(event, key)
          return if id.nil? || preceding.any? { |earlier| earlier[:aggregate] == key && earlier[:id].to_s == id }

          "#{command.hecks_name} (#{@own}##{event[:id]}) was accepted referencing #{key}##{id}, " \
            "but no earlier event created that record"
        end

        # The `"Domain::Aggregate"` key the reference points at; nil when the target is not an
        # aggregate of this domain (a cross-domain reference this property cannot read).
        def target_key(command)
          target = Naming.demodulise(command.references)
          return @own if @own.split("::").last == target

          "#{@domain}::#{target}" if @bluebook.aggregates.any? { |candidate| candidate.hecks_name == target }
        end

        # The id the emission addressed: the event's own id when the command references its own
        # aggregate, else the reference key's scalar in the payload. nil when not a plain scalar.
        def referenced_id(event, key)
          return event[:id].to_s if key == @own

          value = read(Hash(event[:payload]), Naming.reference_key(key.split("::").last))
          value = read(value, :value) if value.is_a?(Hash)
          value.to_s if value.is_a?(String) || value.is_a?(Numeric)
        end

        # A payload spells its keys as strings or symbols; neither is preferred.
        def read(hash, name)
          hash.fetch(name.to_sym) { hash[name.to_s] }
        end
      end

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
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each emission with a dangling reference
        def references_resolve_to_earlier_records(history)
          events = Array(history[:events])

          violations = (history[:bluebooks] || {}).flat_map do |domain, bluebook|
            bluebook.aggregates.flat_map { |aggregate| ReferenceReading.new(domain, bluebook, aggregate, events).dangling }
          end
          violations.empty? || violations.uniq.join("; ")
        end
      end
    end
  end
end
