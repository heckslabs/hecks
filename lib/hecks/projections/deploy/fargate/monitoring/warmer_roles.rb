module Hecks
  module Projections
    module Deploy
      module Fargate
        module Monitoring
          # The IAM roles and the schedule of the synthetic check. Extended onto `Monitoring`.
          module WarmerRoles
            private

            def warmer_role_text(ids)
              <<~ROLE
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

            def scheduler_role_text(ids)
              <<~ROLE
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

            def schedule_text(warmer, ids)
              <<~SCHEDULE
                #{ids[:warmer_schedule]}:
                  Type: AWS::Scheduler::Schedule
                  Properties:
                    Name: !Sub "${AWS::StackName}-warmer"
                    Description: #{Yaml.string(warmer[:schedule_description] || "Runs the synthetic check against the CDN.")}
                    ScheduleExpression: #{warmer[:rate].to_json}
                    FlexibleTimeWindow: { Mode: "OFF" }
                    Target:
                      Arn: !GetAtt #{ids[:warmer_function]}.Arn
                      RoleArn: !GetAtt #{ids[:scheduler_role]}.Arn
              SCHEDULE
            end
          end
        end
      end
    end
  end
end
