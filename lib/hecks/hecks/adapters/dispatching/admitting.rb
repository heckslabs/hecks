# frozen_string_literal: true

require "time"
require "hecks/roundhouse/adapters/metering"
require_relative "signalbox_door"

module Hecks
  module Adapters
    class Dispatching
      # Admission by headroom for a fill (ADR 0222, phase 3, admission): each planned coder is put
      # to Signalbox's `Admission.Admit`, and the given that refuses it is why it waits. It only
      # assembles the facts the command takes; every comparison is a given of the bluebook.
      #
      # One beat is read per fill. Each coder this fill already admitted takes its expected draw off
      # the headroom and counts against the ramp, beside the runs started inside the ramp window.
      class Admitting
        # The ramp when the Signalbox world declares none: one start a minute.
        RAMP = { step: 1, window_seconds: 60 }.freeze
        # A coder's fuse when the world declares none.
        FUSE = { coder_mb: 4_096, coder_minutes: 240 }.freeze

        # Roundhouse's meter over a registry that holds the AgentRun ledger, so the beat meters each
        # live coder's draw; the one meter every caller of admission hands the door.
        #
        # @param registry [Runtime::Registry] the Hecks registry the fill or the check runs in
        # @return [Proc] answers the machine facts as {Metering#machine_facts} does
        def self.meter(registry) = -> { Metering.new(registry: registry).machine_facts }

        # @param runs [Hash{String => Hash}] each agent run's key with its `started_at`
        # @param now [Time] the time of the fill
        # @param door [SignalboxDoor] the handle on Signalbox
        # @param switch [Boolean] whether the owner's switch lets new work start
        # @param meter [#call, nil] the machine facts the beat looks at ({.meter}); nil leaves the
        #   door's Signalbox to meter the machine itself
        def initialize(runs:, now:, door: SignalboxDoor.shared, switch: true, meter: nil)
          @door = door
          @beat = meter ? door.look(meter: meter) : door.look
          @ramp = RAMP.merge(door.setting("ramp"))
          @fuse = FUSE.merge(door.setting("fuses"))
          @recent = runs.select { |_key, run| recent?(run[:started_at], now) }.keys
          @switch = switch
        end

        # @param item [Plan::Item] the planned coder
        # @param chosen [Integer] the coders this fill already admitted
        # @param outranked [Integer] the coders earlier in merit order this fill left waiting
        # @return [String, nil] `skipped: signalbox: <the given>`, nil when it is admitted
        def reason(item, chosen: 0, outranked: 0)
          refused = @door.refusal(facts(item, chosen, outranked))
          "skipped: signalbox: #{refused}" if refused
        end

        # The band is the worse of the memory band and the load band, so the clause sets the load
        # and its marks beside the memory facts: either can be what put the band where it stands.
        #
        # @return [String] the clause a fill's header says in place of the cap
        def clause
          "admission by headroom #{@beat[:headroom]} MB (#{@beat[:band]}; memory pressure level " \
            "#{@beat[:memory_pressure_level].to_i}; #{draw_words}, floor #{@beat[:floor]}, gap #{@beat[:gap]}; " \
            "#{load_words}; ramp #{@ramp[:step]} per #{@ramp[:window_seconds]}s)"
        end

        private

        # The 1-minute load, held in hundredths, on the cores it is read against, and the marks the
        # bluebook judges it by, as the world declares them in percent of those cores.
        def load_words
          format("load %<load>.2f on %<cores>d cores, tight %<tight>d%%, short %<short>d%% of cores",
                 load: @beat[:load].to_i / 100.0, cores: @beat[:cores].to_i,
                 tight: @beat[:load_tight].to_i, short: @beat[:load_short].to_i)
        end

        def facts(item, chosen, outranked)
          wrap(**labels(item), **machine(chosen), **counts(item, chosen, outranked))
        end

        # A fill starts a coder for a planned Work item: Delegate asks, its purpose is not met.
        def labels(item)
          { admission: item.key, role: "coder", tier: WorkItems.tier(item), owner: "delegate", purpose: item.key,
            ends_when: "the branch lands or the item yields", asked_by: "delegate", met: "no",
            switch: @switch ? "on" : "off" }
        end

        # The draw the beat chose, named by where it came from: Roundhouse's metered median, or the
        # world's while no coder is metered.
        def draw_words
          source = @beat[:metered_draw].to_i.positive? ? "metered" : "the world's"
          "draw #{@beat[:draw]} #{source}"
        end

        def machine(chosen)
          draw = @beat[:draw].to_i
          { band: @beat[:band], headroom: @beat[:headroom].to_i - (draw * chosen), floor: @beat[:floor],
            gap: @beat[:gap], age: @beat[:age], stale_after: @beat[:stale_after], draw: draw,
            memory_pressure_level: @beat[:memory_pressure_level].to_i,
            fuse: @fuse[:coder_mb], fuse_minutes: @fuse[:coder_minutes] }
        end

        # Only a coder asks here: the helper share, the seat count and the MCP servers bind other
        # roles or a session's own start (later steps), so they are nought; congestion stays
        # Delegate's overlap hold until its own step moves it.
        def counts(item, chosen, outranked)
          started = @recent.count { |key| key != item.key } + chosen
          { started: started, ramp: @ramp[:step], coders: 0, helpers: 0, share: 0, outranked: outranked,
            seats: 0, unused_servers: 0, curtailed: 0 }
        end

        def recent?(started_at, now)
          now - Time.parse(started_at.to_s) < @ramp[:window_seconds].to_i
        rescue ArgumentError, TypeError
          false
        end

        def wrap(**facts) = facts.transform_values { |fact| { value: fact } }
      end
    end
  end
end
