module Hecks
  module Adapters
    module Driving
      module Clock
        # Converts between Unix seconds and the wall-clock time of a named time zone, through the
        # operating system's own zone database (`TZ`). The gem carries no zone data of its own.
        #
        # `TZ` is process-wide, so every conversion holds one lock while it is set.
        module ZoneTime
          # Where the operating system keeps its zone files.
          ZONEINFO = %w[/usr/share/zoneinfo /usr/lib/zoneinfo /usr/share/lib/zoneinfo].freeze

          LOCK = Mutex.new
          private_constant :LOCK

          module_function

          # @param zone [String, nil] a time zone name; nil is UTC
          # @return [Boolean] whether the operating system knows the zone
          def known?(zone)
            return true if zone.nil?
            return false if zone.include?("..") || zone.start_with?("/")

            ZONEINFO.any? { |root| File.file?(File.join(root, zone)) }
          end

          # @param epoch [Integer] Unix seconds
          # @param zone [String, nil] a time zone name; nil is UTC
          # @return [Time] that instant as the zone's wall clock reads it
          def local(epoch, zone)
            return Time.at(epoch).utc if zone.nil?

            within(zone) { Time.at(epoch).localtime }
          end

          # @param zone [String, nil] a time zone name; nil is UTC
          # @param parts [Array<Integer>] year, month, day, hour and minute on the zone's wall clock
          # @return [Integer] the Unix seconds of that wall-clock minute
          def epoch(zone, *parts)
            return Time.utc(*parts).to_i if zone.nil?

            within(zone) { Time.local(*parts).to_i }
          end

          # Runs the block with `TZ` set to the zone, putting back what was there.
          def within(zone)
            LOCK.synchronize do
              saved = ENV.fetch("TZ", nil)
              ENV["TZ"] = zone
              yield
            ensure
              ENV["TZ"] = saved
            end
          end
          private_class_method :within
        end
      end
    end
  end
end
