module Hecks
  module Projections
    module Deploy
      module Fargate
        module Monitoring
          # The synthetic check: a Lambda function that requests real paths through the CDN, its
          # schedule and the alarm on what it reports. Extended onto `Monitoring`.
          module Warmer
            private

            def warmer_blocks(alerts, context)
              namespace = alerts[:warmer][:namespace] || "#{context[:stack_name]}/Synthetic"
              warmer = alerts[:warmer]
              ids = context[:ids]
              [warmer_role_text(ids).rstrip, warmer_function_yaml(warmer, namespace, context),
               synthetic_alarm_yaml(warmer, namespace, context), scheduler_role_text(ids).rstrip,
               schedule_text(warmer, ids).rstrip]
            end

            def warmer_function_yaml(warmer, namespace, context)
              code = Yaml.indent(warmer[:code] || warmer_code(warmer, namespace), "        ")
              "#{function_head(context).rstrip}\n#{code}".rstrip
            end

            def function_head(context)
              <<~FUNCTION
                # Requests each real path through the CDN and reports how many failed. It always reports a
                # data point, even zero, so the alarm below treats silence as a finding.
                #{context[:ids][:warmer_function]}:
                  Type: AWS::Lambda::Function
                  Properties:
                    FunctionName: #{context[:stack_name]}-warmer
                    Runtime: nodejs22.x
                    Architectures: [arm64]
                    Handler: index.handler
                    MemorySize: 128
                    Timeout: 20
                    Role: !GetAtt #{context[:ids][:warmer_role]}.Arn
                    Environment:
                      Variables:
                        CLOUDFRONT_DOMAIN: !GetAtt #{context[:distribution_id]}.DomainName
                    Code:
                      ZipFile: |
              FUNCTION
            end

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

            def synthetic_alarm_yaml(warmer, namespace, context)
              ids = context[:ids]
              alarm = { period: 60, evaluation_periods: 1, threshold: 1 }
              lines = [
                "#{ids[:synthetic_alarm]}:", "  Type: AWS::CloudWatch::Alarm", "  Properties:",
                "    AlarmName: #{context[:stack_name]}-synthetic-check",
                alarm_description(warmer[:alarm_description], DESCRIPTIONS[:synthetic]),
                "    Namespace: #{namespace}", "    MetricName: SyntheticCheckFailures", "    Statistic: Maximum"
              ]
              with_settings(lines, alarm, ids, missing: "breaching")
            end
          end
        end
      end
    end
  end
end
