module Hecks
  module Projections
    module Deploy
      module Fargate
        module Monitoring
          # Reads and checks the `alerts` setting of a world. Extended onto `Monitoring`, which
          # supplies the key lists and defaults.
          module Reading
            private

            def alarms(entries, containers)
              raise ArgumentError, "alerts alarms must be a list, got #{entries.inspect}" unless entries.is_a?(Array)

              entries.flat_map do |entry|
                given = alarm_entry(entry)
                kind = Check.one_of!(given[:kind], "alerts alarms kind", KINDS)
                kind == "target_unhealthy" ? unhealthy_alarms(given, containers) : [alarm(kind, given, nil)]
              end
            end

            def alarm_entry(entry)
              return { kind: entry } unless entry.is_a?(Hash)

              Check.hash!(entry, "alerts alarms", allowed: ALARM_KEYS, required: [:kind])
            end

            def unhealthy_alarms(given, containers)
              named = given[:container]&.to_s
              if named && !containers.include?(named)
                raise ArgumentError,
                      "alerts alarms container #{named.inspect} has no target group; have #{containers.join(", ")}"
              end

              (named ? [named] : containers).map { |container| alarm("target_unhealthy", given, container) }
            end

            def alarm(kind, given, container)
              values = DEFAULTS.fetch(kind).merge(given.slice(:threshold, :period, :evaluation_periods, :datapoints_to_alarm))
              values.each { |key, value| Check.integer!(value, "alerts alarms #{key}", range: 1..86_400) }
              values.merge(kind: kind, container: container,
                           description: description!(given[:description], "alerts alarms description"))
            end

            def warmer(value)
              return nil if value.nil?

              given = Check.hash!(value, "alerts warmer", allowed: WARMER_KEYS, required: [:paths])
              paths = warmer_paths(given)
              rate = warmer_rate(given)
              { paths: paths, namespace: given[:namespace]&.to_s, rate: rate, code: given[:code]&.to_s,
                schedule_description: description!(given[:schedule_description], "alerts warmer schedule_description"),
                alarm_description: description!(given[:alarm_description], "alerts warmer alarm_description") }
            end

            def warmer_paths(given)
              paths = Check.strings!(given[:paths], "alerts warmer paths", min: 1)
              bad = paths.reject { |path| path.start_with?("/") }
              return paths if bad.empty?

              raise ArgumentError, "alerts warmer paths must start with /, got #{bad.join(", ")}"
            end

            def warmer_rate(given)
              rate = given.fetch(:rate, "rate(1 minute)").to_s
              return rate if rate.match?(/\A(rate|cron)\(.+\)\z/)

              raise ArgumentError,
                    "alerts warmer rate must be a schedule expression such as rate(1 minute), got #{rate.inspect}"
            end

            def description!(value, where)
              return nil if value.nil?

              text = value.to_s
              return text if (1..1023).cover?(text.length)

              raise ArgumentError, "#{where} must be 1 to 1023 characters, got #{value.inspect}"
            end
          end
        end
      end
    end
  end
end
