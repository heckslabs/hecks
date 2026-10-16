require_relative "patterns"

module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # Reads the `logs` and `log_retention_days` settings: where the containers' logs go and
          # how long CloudWatch keeps them. Extended onto `Settings`.
          #
          # Retention is one of CloudWatch's own values and never "never expire", so a box's log
          # bill is bounded by a declaration.
          module LogReaders
            include Patterns

            # @param settings [Hash{Symbol => Object}] the world's `AwsBox` settings
            # @return [Hash{Symbol => Object}] the plan's `logs` and `log_retention_days`
            # @raise [ArgumentError] when `logs` is not a known destination, or the retention is not
            #   a value CloudWatch accepts
            def read_logs(settings)
              destination = settings.fetch(:logs, "cloudwatch").to_s
              raise ArgumentError, LOGS_SHAPE unless LOG_DESTINATIONS.include?(destination)

              days = settings.fetch(:log_retention_days, DEFAULT_LOG_RETENTION_DAYS)
              raise ArgumentError, retention_refusal(days) unless LOG_RETENTION_DAYS.include?(days)

              { logs: destination, log_retention_days: days }
            end

            private

            def retention_refusal(days)
              "log_retention_days: #{days.inspect} is not a CloudWatch retention; use one of #{LOG_RETENTION_DAYS.join(", ")}"
            end
          end
        end
      end
    end
  end
end
