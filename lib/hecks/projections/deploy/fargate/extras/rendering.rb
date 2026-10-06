module Hecks
  module Projections
    module Deploy
      module Fargate
        module Extras
          # Renders the buckets, generated secrets and IAM policies of a world. Extended onto
          # `Extras`.
          module Rendering
            private

            def bucket_blocks(bucket)
              blocks = [bucket_yaml(bucket)]
              blocks << bucket_policy_yaml(bucket).rstrip if bucket[:public_read]
              blocks
            end

            def bucket_yaml(bucket)
              lines = ["#{bucket[:id]}:", "  Type: AWS::S3::Bucket", "  Properties:",
                       "    BucketName: !Sub \"#{bucket[:name_prefix]}-${AWS::AccountId}\""]
              lines.concat(public_access_lines) if bucket[:public_read]
              lines.concat(cors_lines(bucket[:cors_origins])) unless bucket[:cors_origins].empty?
              lines.join("\n")
            end

            def public_access_lines
              ["    PublicAccessBlockConfiguration:", "      BlockPublicAcls: false", "      BlockPublicPolicy: false",
               "      IgnorePublicAcls: false", "      RestrictPublicBuckets: false"]
            end

            def cors_lines(origins)
              ["    CorsConfiguration:", "      CorsRules:", "        - AllowedOrigins: #{Yaml.flow_list(origins)}",
               "          AllowedMethods: [GET]", "          AllowedHeaders: [\"*\"]"]
            end

            def bucket_policy_yaml(bucket)
              <<~POLICY
                #{bucket[:id]}Policy:
                  Type: AWS::S3::BucketPolicy
                  Properties:
                    Bucket: !Ref #{bucket[:id]}
                    PolicyDocument:
                      Version: "2012-10-17"
                      Statement:
                        - Effect: Allow
                          Principal: "*"
                          Action: s3:GetObject
                          Resource: !Sub "${#{bucket[:id]}.Arn}/*"
              POLICY
            end

            def secret_yaml(secret)
              lines = ["#{secret[:id]}:", "  Type: AWS::SecretsManager::Secret", "  Properties:", "    Name: #{secret[:name]}"]
              lines << "    Description: #{Yaml.string(secret[:description])}" if secret[:description]
              lines.push("    GenerateSecretString:", "      SecretStringTemplate: '{}'",
                         "      GenerateStringKey: #{secret[:key]}", "      PasswordLength: #{secret[:length]}",
                         "      ExcludePunctuation: true")
              lines.join("\n")
            end

            def policy_yaml(policy)
              lines = ["- PolicyName: #{policy[:name]}", "  PolicyDocument:", "    Version: '2012-10-17'", "    Statement:"]
              policy[:statements].each do |statement|
                lines << "      - Effect: #{statement[:effect]}"
                lines.concat(statement_list("Action", statement[:actions]))
                lines.concat(statement_list("Resource", statement[:resources].map { |resource| Yaml.string(resource) }))
              end
              "#{lines.join("\n")}\n"
            end

            # One entry is written as a scalar, the form IAM policies usually take; more are a list.
            def statement_list(key, values)
              return ["        #{key}: #{values.first}"] if values.one?

              ["        #{key}:"] + values.map { |value| "          - #{value}" }
            end
          end
        end
      end
    end
  end
end
