require_relative "check"
require_relative "yaml"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # Alerting for a Fargate stack: an `SNS` topic, CloudWatch alarms, and an
        # optional synthetic check.
        module Monitoring
          module_function

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
            blocks = [topic_yaml(alerts, context[:ids])]
            blocks << subscription_yaml(alerts, context[:ids]) if alerts[:email]
            blocks << monitoring_subscription_yaml(context) if cloudfront_metrics?(alerts)
            blocks.concat(alerts[:alarms].flat_map { |alarm| alarm_blocks(alarm, context) })
            blocks.concat(warmer_blocks(alerts, context)) if alerts[:warmer]
            "#{blocks.join("\n\n")}\n\n"
          end

          def alarms(entries, containers)
            raise ArgumentError, "alerts alarms must be a list, got #{entries.inspect}" unless entries.is_a?(Array)

            entries.flat_map do |entry|
              given = if entry.is_a?(Hash)
                        Check.hash!(entry, "alerts alarms", allowed:  ALARM_KEYS,
                                                            required: [:kind])
                      else
                        { kind: entry }
                      end
              kind = Check.one_of!(given[:kind], "alerts alarms kind", KINDS)
              kind == "target_unhealthy" ? unhealthy_alarms(given, containers) : [alarm(kind, given, nil)]
            end
          end
          private_class_method :alarms

          def unhealthy_alarms(given, containers)
            named = given[:container]&.to_s
            if named && !containers.include?(named)
              raise ArgumentError,
                    "alerts alarms container #{named.inspect} has no target group; have #{containers.join(', ')}"
            end

            (named ? [named] : containers).map { |container| alarm("target_unhealthy", given, container) }
          end
          private_class_method :unhealthy_alarms

          def alarm(kind, given, container)
            values = DEFAULTS.fetch(kind).merge(given.slice(:threshold, :period, :evaluation_periods, :datapoints_to_alarm))
            values.each { |key, value| Check.integer!(value, "alerts alarms #{key}", range: 1..86_400) }
            values.merge(kind: kind, container: container,
                         description: description!(given[:description], "alerts alarms description"))
          end
          private_class_method :alarm

          def warmer(value)
            return nil if value.nil?

            given = Check.hash!(value, "alerts warmer", allowed: WARMER_KEYS, required: [:paths])
            paths = Check.strings!(given[:paths], "alerts warmer paths", min: 1)
            unless paths.all? { |path| path.start_with?("/") }
              raise ArgumentError, "alerts warmer paths must start with /, got #{paths.reject do |p|
                p.start_with?('/')
              end.join(', ')}"
            end

            rate = given.fetch(:rate, "rate(1 minute)").to_s
            unless rate.match?(/\A(rate|cron)\(.+\)\z/)
              raise ArgumentError,
                    "alerts warmer rate must be a schedule expression such as rate(1 minute), got #{rate.inspect}"
            end

            { paths: paths, namespace: given[:namespace]&.to_s, rate: rate, code: given[:code]&.to_s,
              schedule_description: description!(given[:schedule_description], "alerts warmer schedule_description"),
              alarm_description: description!(given[:alarm_description], "alerts warmer alarm_description") }
          end
          private_class_method :warmer

          def description!(value, where)
            return nil if value.nil?

            text = value.to_s
            unless (1..1023).cover?(text.length)
              raise ArgumentError,
                    "#{where} must be 1 to 1023 characters, got #{value.inspect}"
            end

            text
          end
          private_class_method :description!

          def topic_yaml(alerts, ids)
            <<~TOPIC.rstrip
              #{ids[:alerts_topic]}:
                Type: AWS::SNS::Topic
                Properties:
                  TopicName: #{alerts[:topic]}
            TOPIC
          end
          private_class_method :topic_yaml

          def subscription_yaml(alerts, ids)
            <<~SUBSCRIPTION.rstrip
              # SNS holds an email subscription as pending until the recipient follows the
              # confirmation link SNS mails on stack creation; no alert is delivered before then.
              #{ids[:alerts_subscription]}:
                Type: AWS::SNS::Subscription
                Properties:
                  TopicArn: !Ref #{ids[:alerts_topic]}
                  Protocol: email
                  Endpoint: #{alerts[:email]}
            SUBSCRIPTION
          end
          private_class_method :subscription_yaml

          def monitoring_subscription_yaml(context)
            ids = context[:ids]
            <<~MONITORING.rstrip
              # CloudFront publishes per-minute metrics only for a distribution that opts in.
              #{ids[:cloudfront_monitoring]}:
                Type: AWS::CloudFront::MonitoringSubscription
                Properties:
                  DistributionId: !Ref #{context[:distribution_id]}
                  MonitoringSubscription:
                    RealtimeMetricsSubscriptionConfig:
                      RealtimeMetricsSubscriptionStatus: Enabled
            MONITORING
          end
          private_class_method :monitoring_subscription_yaml

          def alarm_blocks(alarm, context)
            case alarm[:kind]
            when "alb_5xx" then [alb_alarm_yaml(alarm, context)]
            when "target_unhealthy" then [unhealthy_alarm_yaml(alarm, context)]
            else [cloudfront_alarm_yaml(alarm, context)]
            end
          end
          private_class_method :alarm_blocks

          def alarm_description(given, default)
            "    AlarmDescription: #{Yaml.string(given || default)}"
          end
          private_class_method :alarm_description

          def alarm_settings(alarm, ids, missing: "notBreaching", period: true)
            lines = []
            lines << "Period: #{alarm[:period]}" if period
            lines << "EvaluationPeriods: #{alarm[:evaluation_periods]}"
            lines << "DatapointsToAlarm: #{alarm[:datapoints_to_alarm]}" if alarm[:datapoints_to_alarm]
            lines.push("Threshold: #{alarm[:threshold]}", "ComparisonOperator: GreaterThanOrEqualToThreshold",
                       "TreatMissingData: #{missing}", "AlarmActions: [!Ref #{ids[:alerts_topic]}]",
                       "OKActions: [!Ref #{ids[:alerts_topic]}]")
          end
          private_class_method :alarm_settings

          def alb_alarm_yaml(alarm, context)
            ids = context[:ids]
            lines = [
              "#{ids[:alb_5xx_alarm]}:", "  Type: AWS::CloudWatch::Alarm", "  Properties:",
              "    AlarmName: #{context[:stack_name]}-alb-5xx",
              alarm_description(alarm[:description], DESCRIPTIONS[:alb_5xx]),
              "    Namespace: AWS/ApplicationELB", "    MetricName: HTTPCode_Target_5XX_Count",
              "    Dimensions:", "      - Name: LoadBalancer", "        Value: !GetAtt #{context[:alb_id]}.LoadBalancerFullName",
              "    Statistic: Sum"
            ]
            (lines + alarm_settings(alarm, ids).map { |line| "    #{line}" }).join("\n")
          end
          private_class_method :alb_alarm_yaml

          def unhealthy_alarm_yaml(alarm, context)
            ids = context[:ids]
            container = alarm[:container]
            group = context[:target_groups].fetch(container)
            lines = [
              "#{Yaml.camel(container)}TargetUnhealthyAlarm:", "  Type: AWS::CloudWatch::Alarm", "  Properties:",
              "    AlarmName: #{context[:stack_name]}-#{container}-unhealthy",
              alarm_description(alarm[:description], format(DESCRIPTIONS[:target_unhealthy], container: container)),
              "    Namespace: AWS/ApplicationELB", "    MetricName: UnHealthyHostCount",
              "    Dimensions:", "      - Name: LoadBalancer", "        Value: !GetAtt #{context[:alb_id]}.LoadBalancerFullName",
              "      - Name: TargetGroup", "        Value: !GetAtt #{group}.TargetGroupFullName",
              "    Statistic: Maximum"
            ]
            (lines + alarm_settings(alarm, ids).map { |line| "    #{line}" }).join("\n")
          end
          private_class_method :unhealthy_alarm_yaml

          def cloudfront_alarm_yaml(alarm, context)
            ids = context[:ids]
            distribution = context[:distribution_id]
            lines = [
              "#{ids[:cloudfront_5xx_alarm]}:", "  Type: AWS::CloudWatch::Alarm", "  DependsOn: #{ids[:cloudfront_monitoring]}",
              "  Properties:", "    AlarmName: #{context[:stack_name]}-cloudfront-5xx",
              alarm_description(alarm[:description], DESCRIPTIONS[:cloudfront_5xx]),
              "    Metrics:",
              *edge_metric_lines(distribution)
            ]
            (lines + alarm_settings(alarm, ids, period: false).map { |line| "    #{line}" }).join("\n")
          end
          private_class_method :cloudfront_alarm_yaml

          # A count rather than the raw percentage: at low traffic one failed request reads as a
          # large rate, so the count is the rate applied to that minute's requests.
          def edge_metric_lines(distribution)
            [
              "      - Id: errors", "        Label: CloudFront 5xx responses", "        Expression: rate * requests / 100",
              "        ReturnData: true",
              *metric_stat_lines("rate", "Average", "5xxErrorRate", distribution),
              *metric_stat_lines("requests", "Sum", "Requests", distribution)
            ]
          end
          private_class_method :edge_metric_lines

          def metric_stat_lines(id, stat, metric, distribution)
            [
              "      - Id: #{id}", "        ReturnData: false", "        MetricStat:", "          Stat: #{stat}",
              "          Period: 60", "          Metric:", "            Namespace: AWS/CloudFront",
              "            MetricName: #{metric}",
              "            Dimensions:", "              - Name: DistributionId", "                Value: !Ref #{distribution}",
              "              - Name: Region", "                Value: Global"
            ]
          end
          private_class_method :metric_stat_lines

          def warmer_blocks(alerts, context)
            namespace = alerts[:warmer][:namespace] || "#{context[:stack_name]}/Synthetic"
            warmer = alerts[:warmer]
            [warmer_role_yaml(context[:ids]), warmer_function_yaml(warmer, namespace, context),
             synthetic_alarm_yaml(warmer, namespace, context), scheduler_role_yaml(context[:ids]),
             schedule_yaml(warmer, context[:ids])]
          end
          private_class_method :warmer_blocks

          def warmer_role_yaml(ids)
            <<~ROLE.rstrip
              #{ids[:warmer_role]}:
                Type: AWS::IAM::Role
                Properties:
                  AssumeRolePolicyDocument:
                    Version: '2012-10-17'
                    Statement:
                      - Effect: Allow
                        Principal: { Service: lambda.amazonaws.com }
                        Action: sts:AssumeRole
                  ManagedPolicyArns:
                    - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
                  Policies:
                    - PolicyName: PutMetric
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          # PutMetricData accepts no resource-level permission, so "*" is the only form.
                          - Effect: Allow
                            Action: cloudwatch:PutMetricData
                            Resource: "*"
            ROLE
          end
          private_class_method :warmer_role_yaml

          def warmer_function_yaml(warmer, namespace, context)
            ids = context[:ids]
            head = <<~FUNCTION.rstrip
              # Requests each real path through the CDN and reports how many failed. It always reports a
              # data point, even zero, so the alarm below treats silence as a finding.
              #{ids[:warmer_function]}:
                Type: AWS::Lambda::Function
                Properties:
                  FunctionName: #{context[:stack_name]}-warmer
                  Runtime: nodejs22.x
                  Architectures: [arm64]
                  Handler: index.handler
                  MemorySize: 128
                  Timeout: 20
                  Role: !GetAtt #{ids[:warmer_role]}.Arn
                  Environment:
                    Variables:
                      CLOUDFRONT_DOMAIN: !GetAtt #{context[:distribution_id]}.DomainName
                  Code:
                    ZipFile: |
            FUNCTION
            "#{head}\n#{Yaml.indent(warmer[:code] || warmer_code(warmer, namespace), '        ')}".rstrip
          end
          private_class_method :warmer_function_yaml

          def warmer_code(warmer, namespace)
            <<~CODE
              const { CloudWatchClient, PutMetricDataCommand } = require("@aws-sdk/client-cloudwatch");
              const cw = new CloudWatchClient({});
              const PATHS = #{warmer[:paths].to_json};
              exports.handler = async () => {
                const host = process.env.CLOUDFRONT_DOMAIN;
                let failures = 0;
                const results = await Promise.all(PATHS.map(async (path) => {
                  try {
                    const res = await fetch(`https://${host}${path}`);
                    if (res.status !== 200) failures++;
                    return `${path}: ${res.status} (x-cache: ${res.headers.get("x-cache")})`;
                  } catch (err) {
                    failures++;
                    return `${path}: FAILED ${err}`;
                  }
                }));
                console.log(results.join("\\n"));
                await cw.send(new PutMetricDataCommand({
                  Namespace: #{namespace.to_json},
                  MetricData: [{ MetricName: "SyntheticCheckFailures", Value: failures, Unit: "Count" }],
                }));
              };
            CODE
          end
          private_class_method :warmer_code

          def synthetic_alarm_yaml(warmer, namespace, context)
            ids = context[:ids]
            alarm = { period: 60, evaluation_periods: 1, threshold: 1 }
            lines = [
              "#{ids[:synthetic_alarm]}:", "  Type: AWS::CloudWatch::Alarm", "  Properties:",
              "    AlarmName: #{context[:stack_name]}-synthetic-check",
              alarm_description(warmer[:alarm_description], DESCRIPTIONS[:synthetic]),
              "    Namespace: #{namespace}", "    MetricName: SyntheticCheckFailures", "    Statistic: Maximum"
            ]
            (lines + alarm_settings(alarm, ids, missing: "breaching").map { |line| "    #{line}" }).join("\n")
          end
          private_class_method :synthetic_alarm_yaml

          def scheduler_role_yaml(ids)
            <<~ROLE.rstrip
              #{ids[:scheduler_role]}:
                Type: AWS::IAM::Role
                Properties:
                  AssumeRolePolicyDocument:
                    Version: '2012-10-17'
                    Statement:
                      - Effect: Allow
                        Principal: { Service: scheduler.amazonaws.com }
                        Action: sts:AssumeRole
                  Policies:
                    - PolicyName: InvokeWarmer
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: lambda:InvokeFunction
                            Resource: !GetAtt #{ids[:warmer_function]}.Arn
            ROLE
          end
          private_class_method :scheduler_role_yaml

          def schedule_yaml(warmer, ids)
            <<~SCHEDULE.rstrip
              #{ids[:warmer_schedule]}:
                Type: AWS::Scheduler::Schedule
                Properties:
                  Name: !Sub "${AWS::StackName}-warmer"
                  Description: #{Yaml.string(warmer[:schedule_description] || 'Runs the synthetic check against the CDN.')}
                  ScheduleExpression: #{warmer[:rate].to_json}
                  FlexibleTimeWindow: { Mode: "OFF" }
                  Target:
                    Arn: !GetAtt #{ids[:warmer_function]}.Arn
                    RoleArn: !GetAtt #{ids[:scheduler_role]}.Arn
            SCHEDULE
          end
          private_class_method :schedule_yaml
        end
      end
    end
  end
end
