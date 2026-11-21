# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The two signals a fill holds on when the launcher's boots run away, declared in the Tickets
      # world: a boot storm (one caller booting over a rate) and the boot share (the boots' share
      # of the machine's CPU over the load's high mark). The day's hours (`cpu_budget`) stay a
      # reading for the board and hold nothing. It reads the `boots`, `load`, `max_load` and `cpus`
      # of the {Settings} that includes it.
      module BootGuard
        # The world verb that carries the storm rate: boots by one caller in a window of minutes.
        BOOT_STORM = "boot_storm"

        # The world verb that carries the boot share mark, in percent of the CPU, over minutes.
        BOOT_SHARE = "boot_share"

        # A storm when the world declares none: more than 30 boots by one caller in 5 minutes.
        STORM_BOOTS = 30
        STORM_MINUTES = 5

        # A share mark when the world declares none: 25 percent of the CPU over 15 minutes.
        SHARE_PERCENT = 25.0
        SHARE_MINUTES = 15

        # @return [Hash{String => Integer}] each named caller booting over the storm rate now
        def boot_storms = @boots.storms(boots: storm_rate[:boots], minutes: storm_rate[:minutes])

        # @param key [String] a work item's key, which is its run key
        # @return [String, nil] why that item's own run is held: its caller is a boot storm; other
        #   callers and items are not
        def storm_reason(key)
          caller_name, count = boot_storms.find { |name, _| name == key || name.end_with?(":#{key}") }
          return unless caller_name

          "skipped: boot storm: #{caller_name} booted #{count} times in #{storm_rate[:minutes]} minutes"
        end

        # @return [Hash, nil] `load:` the boot share in percent and `rating:` the mark, when the
        #   load is over its high mark; nil when it is not, so a boot-heavy minute at low load holds
        #   nothing. A read cut short is a floor, which holds only if the floor is over the mark.
        def boot_share_reading
          return unless load > max_load

          { load: boot_share_percent.round, rating: share_mark[:percent].round }
        end

        # @return [String, nil] why no session starts: the boots took more than the mark's share of
        #   the CPU while the load is over its high mark; nil otherwise
        def boot_stop
          reading = boot_share_reading
          return unless reading && share_now.percent > share_mark[:percent]

          "skipped: boot share #{share_now.percent}% of CPU over #{share_mark[:percent]}% in the last " \
            "#{share_mark[:minutes]} minutes, at load #{load.round(1)} > #{max_load.round(1)}"
        end

        # @return [Float] the share of the CPU, in percent, above which the boots hold a fill at a
        #   high load
        def boot_share_mark = share_mark[:percent]

        # @return [Float] the boots' share of the CPU over the share window now, in percent
        def boot_share_percent = share_now.percent

        # @return [Time, nil] when the oldest boots leave the share's window far enough to free it
        def boot_frees_at
          @boots.share_frees_at(percent: share_mark[:percent], minutes: share_mark[:minutes], cpus: cpus)
        end

        private

        def share_now = @share_now ||= @boots.share(minutes: share_mark[:minutes], cpus: cpus)

        def share_mark
          declared = declared(BOOT_SHARE)
          { percent: (declared[:percent] || SHARE_PERCENT).to_f, minutes: Integer(declared[:minutes] || SHARE_MINUTES) }
        end

        def storm_rate
          declared = declared(BOOT_STORM)
          { boots: Integer(declared[:boots] || STORM_BOOTS), minutes: Integer(declared[:minutes] || STORM_MINUTES) }
        end
      end
    end
  end
end
