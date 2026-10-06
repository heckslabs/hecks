require_relative "check"
require_relative "yaml"
require_relative "monitoring/reading"
require_relative "monitoring/topic"
require_relative "monitoring/alarms"
require_relative "monitoring/warmer_roles"
require_relative "monitoring/warmer"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # Alerting for a Fargate stack: an `SNS` topic, CloudWatch alarms, and an
        # optional synthetic check.
        module Monitoring
          KEYS = [:topic, :email, :alarms, :warmer].freeze
          KINDS = %w[alb_5xx target_unhealthy cloudfront_5xx].freeze
          ALARM_KEYS = [:kind, :container, :threshold, :period, :evaluation_periods, :datapoints_to_alarm, :description].freeze
          WARMER_KEYS = [:paths, :namespace, :rate, :code, :schedule_description, :alarm_description].freeze
          EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
          DEFAULTS = {
            "alb_5xx"          => { threshold: 1, period: 60, evaluation_periods: 3, datapoints_to_alarm: 2 },
            "target_unhealthy" => { threshold: 1, period: 60, evaluation_periods: 2 },
            "cloudfront_5xx"   => { threshold: 3, period: 60, evaluation_periods: 3, datapoints_to_alarm: 2 }
          }.freeze

          DESCRIPTIONS = {
            alb_5xx:          "The load balancer is returning 5xx responses from the containers behind it.",
            target_unhealthy: "The %<container>s target group has at least one unhealthy target, " \
                              "whether or not any traffic arrives.",
            cloudfront_5xx:   "CloudFront is serving 5xx responses, measured at the edge.",
            synthetic:        "The synthetic check found a non-200 response on a real path, or stopped reporting."
          }.freeze

          extend Reading
          extend Topic
          extend Alarms
          extend WarmerRoles
          extend Warmer

          module_function

          def normalize(setting, containers:)
            return nil if setting.nil?

            given = Check.hash!(setting, "alerts", allowed: KEYS, required: [:topic])
            email = given[:email]&.to_s
            raise ArgumentError, "alerts email must be an email address, got #{email.inspect}" if email && !EMAIL.match?(email)

            {
              topic: Check.resource_name!(given[:topic], "alerts topic"), email: email,
              alarms: alarms(given.fetch(:alarms, []), containers), warmer: warmer(given[:warmer])
            }
          end

          def cloudfront_metrics?(alerts)
            !alerts.nil? && alerts[:alarms].any? { |alarm| alarm[:kind] == "cloudfront_5xx" }
          end

          def yaml(alerts, context)
            blocks = topic_blocks(alerts, context)
            blocks.concat(alerts[:alarms].flat_map { |alarm| alarm_blocks(alarm, context) })
            blocks.concat(warmer_blocks(alerts, context)) if alerts[:warmer]
            "#{blocks.join("\n\n")}\n\n"
          end
        end
      end
    end
  end
end
