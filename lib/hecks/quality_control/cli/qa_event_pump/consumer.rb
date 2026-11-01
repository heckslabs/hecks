# frozen_string_literal: true

require "hecks/naming"

module Hecks
  module QualityControlCli
    class QaEventPump
      # One attached domain as a consumer: the logs of the domains its hecksagon subscribes to, read
      # past each cursor, with the policies that react to each event run through the domain's own
      # runtime. A subscription to a domain the pump does not attach is named, not read.
      class Consumer
        # @param name [String] the consumer's domain name
        # @param attached [Attached] the attached domains
        # @param cursors [Cursors] where the positions are kept
        def initialize(name, attached:, cursors:)
          @name = name
          @attached = attached
          @cursors = cursors
          @failed = false
        end

        # @return [Boolean] whether reading or reacting stopped this consumer
        def failed? = @failed

        # Reads every attached log this consumer subscribes to, and names each subscription it
        # cannot read.
        #
        # @return [Array<String>] one line per reaction and per problem
        def lines
          producers.flat_map { |producer| read(producer) } + unattached
        end

        private

        def runtime = @attached.runtime(@name)

        def subscribed
          (runtime.registry.hecksagon(@name)&.subscriptions || []).filter_map { |event| Naming.qualifier(event) }.uniq
        end

        def producers = subscribed.select { |domain| @attached.known?(domain) }

        def unattached
          (subscribed - producers).map { |domain| "#{@name} subscribes to #{domain}, which the pump does not attach" }
        end

        # Reads one producer's log past this consumer's cursor, reacting to each entry in turn. A
        # stop leaves the cursor on the last entry that was reacted to.
        def read(producer)
          start = @cursors.position(producer, @name)
          entries = Reader.after(@attached.dir(producer), start)[:events]
          entries.each_with_index.flat_map { |entry, index| react(producer, entry, start + index + 1) }
        rescue StandardError => e
          @failed = true
          ["#{@name} <- #{producer}: stopped, #{e.class}: #{e.message}"]
        end

        # Runs each policy that reacts to the entry, then moves the cursor past it.
        def react(producer, entry, position)
          event = Reader.event(entry)
          lines = runtime.outbox.policies_for(event, producer).flat_map do |policy, home|
            fire(event, policy, home, producer, position)
          end
          @cursors.advance(producer, @name, position)
          lines
        end

        def fire(event, policy, home, producer, position)
          log = runtime.reactions
          before = log.size
          runtime.outbox.react_policy(event, policy: policy, home: home, domain: producer,
                                             event_uid: "#{producer}##{position}")
          log.drop(before).map { |record| describe(record, policy, event, producer) }
        end

        def describe(record, policy, event, producer)
          label = "#{@name} <- #{producer} #{event.name}: #{policy.name}"
          return "reacted: #{label}" if record[:delivered]

          "refused: #{label}: #{record[:reason]}"
        end
      end
    end
  end
end
