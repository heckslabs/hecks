# frozen_string_literal: true

require "fiddle"
require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # Whether the machine is too loaded for the board to add to it: the 1-minute load average
      # against the limit a fill stops at (the Tickets world's `dispatch_max_load`). While it is,
      # {Probe} starts no program and {Snapshot} reads at the slower `loaded_refresh_seconds`. The
      # load is read with no child process, so asking never adds to what it measures. While the
      # owner has `signalbox_pressure` drive it and Signalbox's signal is current, the machine is
      # loaded in the short band instead, and the load average is not compared.
      class LoadGuard
        # Where Linux keeps the load averages.
        PROC = "/proc/loadavg"

        class << self
          # The guard {Probe} asks; nil until a board starts serving, so a reader used alone runs.
          # @return [LoadGuard, nil]
          attr_accessor :shared

          # Makes the guard of this process, the one {Probe} asks from now on. A serving board
          # calls it once; the limit is the one number a fill stops at.
          #
          # @param limit [Numeric] the load above which the machine counts as loaded
          # @param pressure [#call] answers Signalbox's current signal, nil while it does not drive
          # @return [LoadGuard]
          def stand(limit, pressure: -> {}) = self.shared = new(limit: -> { limit }, pressure: pressure)

          # @return [Boolean] whether a guard stands and says the machine is loaded
          def loaded? = shared ? shared.loaded? : false

          # @return [Hash, nil] the standing guard's {#standing}; nil when none stands
          def standing = shared&.standing

          # @return [Hash, nil] the standing guard's {#signal}; nil when none stands
          def signal = shared&.signal

          # The 1-minute load average, from `/proc/loadavg` where there is one, else from the C
          # library's `getloadavg`, which macOS and the BSDs answer.
          #
          # @return [Float] the load, 0.0 when the system reports none
          def reading
            File.readable?(PROC) ? first_figure(File.read(PROC)) : from_library
          rescue SystemCallError, Fiddle::DLError
            0.0
          end

          private

          def first_figure(text) = text.split.first.to_f

          def from_library
            averages = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE, Fiddle::RUBY_FREE)
            read = library_call.call(averages, 1)
            read.positive? ? averages[0, Fiddle::SIZEOF_DOUBLE].unpack1("d") : 0.0
          end

          def library_call
            @library_call ||= Fiddle::Function.new(Fiddle::Handle::DEFAULT["getloadavg"],
                                                   [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
          end
        end

        # @param limit [#call] answers the load above which the machine counts as loaded
        # @param load [#call] answers the 1-minute load average
        # @param now [#call] answers the current time
        # @param pressure [#call] answers Signalbox's current signal, nil while it does not drive
        def initialize(limit:, load: self.class.method(:reading), now: -> { Time.now.utc }, pressure: -> {})
          @limit = limit
          @load = load
          @now = now
          @pressure = pressure
          @since = nil
        end

        # @return [Boolean] whether the machine is loaded now: in the short band while the signal
        #   drives, else the load above the limit
        def loaded?
          signal = @pressure.call
          over = signal ? signals.short?(signal) : @load.call.to_f > @limit.call.to_f
          @since = over ? (@since || @now.call) : nil
          over
        end

        # @return [Hash, nil] `load`, `limit` and `since` (when it became loaded), and `pressure`
        #   while the signal drives, while the machine is loaded; nil otherwise
        def standing
          return unless loaded?

          signal = @pressure.call
          shown = { load: @load.call.to_f.round(1), limit: @limit.call.to_f.round(1), since: @since.iso8601 }
          signal ? shown.merge(pressure: signals.said(signal)) : shown
        end

        # @return [Hash, nil] Signalbox's signal as the strip shows it: its `band`, whether it is
        #   `short`, and what it `said`; nil while the signal does not drive
        def signal
          found = @pressure.call
          found && { band: found[:band].to_s, short: signals.short?(found), said: signals.said(found) }
        end

        # @param program [String] what was not run
        # @return [String] why, as a reader's section shows it
        def refusal(program)
          signal = @pressure.call
          return "#{program} not run: #{signals.said(signal)}" if signal

          "#{program} not run: load #{@load.call.to_f.round(1)} is above #{@limit.call.to_f.round(1)}"
        end

        private

        # Signalbox's reading of a signal, loaded only once a signal is present: the caller that
        # wires `pressure` runs with the load path, and the board's restart code loads this file
        # without one.
        def signals
          require "hecks/signalbox/adapters/pressure_signal"
          PressureSignal
        end
      end
    end
  end
end
