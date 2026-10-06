module Hecks
  module Projections
    module Deploy
      module Fargate
        module Monitoring
          # The alerts topic, its email subscription and the CloudFront metrics subscription.
          # Extended onto `Monitoring`.
          module Topic
            private

            def topic_blocks(alerts, context)
              ids = context[:ids]
              blocks = [topic_text(alerts, ids).rstrip]
              blocks << subscription_text(alerts, ids).rstrip if alerts[:email]
              return blocks unless cloudfront_metrics?(alerts)

              blocks << monitoring_subscription_text(ids, context[:distribution_id]).rstrip
            end

            def topic_text(alerts, ids)
              <<~TOPIC
                #{ids[:alerts_topic]}:
                  Type: AWS::SNS::Topic
                  Properties:
                    TopicName: #{alerts[:topic]}
              TOPIC
            end

            def subscription_text(alerts, ids)
              <<~SUBSCRIPTION
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

            def monitoring_subscription_text(ids, distribution_id)
              <<~MONITORING
                # CloudFront publishes per-minute metrics only for a distribution that opts in.
                #{ids[:cloudfront_monitoring]}:
                  Type: AWS::CloudFront::MonitoringSubscription
                  Properties:
                    DistributionId: !Ref #{distribution_id}
                    MonitoringSubscription:
                      RealtimeMetricsSubscriptionConfig:
                        RealtimeMetricsSubscriptionStatus: Enabled
              MONITORING
            end
          end
        end
      end
    end
  end
end
