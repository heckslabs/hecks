module Hecks
  module Projections
    module Deploy
      module Fargate
        module Monitoring
          # The CloudWatch alarms of a stack. Extended onto `Monitoring`, which supplies the default
          # descriptions.
          module Alarms
            private

            def alarm_blocks(alarm, context)
              case alarm[:kind]
              when "alb_5xx" then [alb_alarm_yaml(alarm, context)]
              when "target_unhealthy" then [unhealthy_alarm_yaml(alarm, context)]
              else [cloudfront_alarm_yaml(alarm, context)]
              end
            end

            def alarm_description(given, default)
              "    AlarmDescription: #{Yaml.string(given || default)}"
            end

            def alarm_settings(alarm, ids, missing: "notBreaching", period: true)
              lines = []
              lines << "Period: #{alarm[:period]}" if period
              lines << "EvaluationPeriods: #{alarm[:evaluation_periods]}"
              lines << "DatapointsToAlarm: #{alarm[:datapoints_to_alarm]}" if alarm[:datapoints_to_alarm]
              lines.push("Threshold: #{alarm[:threshold]}", "ComparisonOperator: GreaterThanOrEqualToThreshold",
                         "TreatMissingData: #{missing}", "AlarmActions: [!Ref #{ids[:alerts_topic]}]",
                         "OKActions: [!Ref #{ids[:alerts_topic]}]")
            end

            def with_settings(lines, alarm, ids, **options)
              (lines + alarm_settings(alarm, ids, **options).map { |line| "    #{line}" }).join("\n")
            end

            def alb_alarm_yaml(alarm, context)
              ids = context[:ids]
              lines = [
                "#{ids[:alb_5xx_alarm]}:", "  Type: AWS::CloudWatch::Alarm", "  Properties:",
                "    AlarmName: #{context[:stack_name]}-alb-5xx",
                alarm_description(alarm[:description], DESCRIPTIONS[:alb_5xx]),
                "    Namespace: AWS/ApplicationELB", "    MetricName: HTTPCode_Target_5XX_Count",
                *load_balancer_dimension(context), "    Statistic: Sum"
              ]
              with_settings(lines, alarm, ids)
            end

            def load_balancer_dimension(context)
              ["    Dimensions:", "      - Name: LoadBalancer", "        Value: !GetAtt #{context[:alb_id]}.LoadBalancerFullName"]
            end

            def unhealthy_alarm_yaml(alarm, context)
              container = alarm[:container]
              group = context[:target_groups].fetch(container)
              lines = unhealthy_head(alarm, context, container) + unhealthy_dimensions(context, group)
              with_settings(lines, alarm, context[:ids])
            end

            def unhealthy_head(alarm, context, container)
              [
                "#{Yaml.camel(container)}TargetUnhealthyAlarm:", "  Type: AWS::CloudWatch::Alarm", "  Properties:",
                "    AlarmName: #{context[:stack_name]}-#{container}-unhealthy",
                alarm_description(alarm[:description], format(DESCRIPTIONS[:target_unhealthy], container: container))
              ]
            end

            def unhealthy_dimensions(context, group)
              [
                "    Namespace: AWS/ApplicationELB", "    MetricName: UnHealthyHostCount",
                "    Dimensions:", "      - Name: LoadBalancer",
                "        Value: !GetAtt #{context[:alb_id]}.LoadBalancerFullName",
                "      - Name: TargetGroup", "        Value: !GetAtt #{group}.TargetGroupFullName",
                "    Statistic: Maximum"
              ]
            end

            def cloudfront_alarm_yaml(alarm, context)
              ids = context[:ids]
              lines = [
                "#{ids[:cloudfront_5xx_alarm]}:", "  Type: AWS::CloudWatch::Alarm", "  DependsOn: #{ids[:cloudfront_monitoring]}",
                "  Properties:", "    AlarmName: #{context[:stack_name]}-cloudfront-5xx",
                alarm_description(alarm[:description], DESCRIPTIONS[:cloudfront_5xx]),
                "    Metrics:",
                *edge_metric_lines(context[:distribution_id])
              ]
              with_settings(lines, alarm, ids, period: false)
            end

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

            def metric_stat_lines(id, stat, metric, distribution)
              [
                "      - Id: #{id}", "        ReturnData: false", "        MetricStat:", "          Stat: #{stat}",
                "          Period: 60", "          Metric:", "            Namespace: AWS/CloudFront",
                "            MetricName: #{metric}",
                "            Dimensions:", "              - Name: DistributionId", "                Value: !Ref #{distribution}",
                "              - Name: Region", "                Value: Global"
              ]
            end
          end
        end
      end
    end
  end
end
