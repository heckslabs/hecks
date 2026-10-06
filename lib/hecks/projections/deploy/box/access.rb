module Hecks
  module Projections
    module Deploy
      module Box
        # The IAM statements of the box's role: the S3 buckets it reads and writes and the Secrets
        # Manager secrets it reads and overwrites. Mixed into `Box`, which supplies `template`.
        module Access
          SECRET_ARN = "arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:".freeze

          # The role's S3 policy: every declared bucket readable, and writable only on a production
          # box, so a rehearsal never changes the real objects.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] a policy list item, indented into the role's `Policies`, or nothing
          def s3_policy(plan)
            return "" if plan.s3_buckets.empty?

            "#{s3_rows(plan.s3_buckets).map { |row| "        #{row}" }.join("\n")}\n"
          end

          # @param resources [Array<String>] the bucket and object ARNs a box may read
          # @return [Array<String>] the policy's head and its read statement, relative to `Policies`
          def s3_read_rows(resources)
            ["- PolicyName: s3-access", "  PolicyDocument:", "    Version: \"2012-10-17\"", "    Statement:",
             "      - Effect: Allow", "        Action: [s3:GetObject, s3:ListBucket]", "        Resource:"] +
              resources.map { |r| "          - !Sub \"#{r}\"" }
          end

          # @param resources [Array<String>] the object ARNs a production box may write
          # @return [Array<String>] the production-only write statement, relative to `Policies`
          def s3_write_rows(resources)
            ["      - !If", "        - IsProduction", "        - Effect: Allow",
             "          Action: [s3:PutObject, s3:DeleteObject]", "          Resource:"] +
              resources.map { |r| "            - !Sub \"#{r}\"" } + ["        - !Ref AWS::NoValue"]
          end

          # One Secrets Manager statement resource per prefix. A name without a trailing `*` gets
          # `-*` for the random suffix AWS appends to every secret ARN.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] YAML list items, one per prefix, ending in a newline
          def secret_resources(plan)
            named = [plan.origin_secret, plan.tunnel_service&.token_secret].compact
            arns = (plan.secret_prefixes + named).map { |name| name.end_with?("*") ? name : "#{name}-*" }
            arns.uniq.map { |pattern| "#{" " * 18}- !Sub \"#{SECRET_ARN}#{pattern}\"\n" }.join.chomp
          end

          # The statement that lets a production box overwrite the secrets named as writable.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] a policy statement for the role, or nothing when none are declared
          def writable_secrets(plan)
            return "" if plan.writable_secrets.empty?

            arns = plan.writable_secrets.map { |name| name.end_with?("*") ? name : "#{name}-*" }.uniq
            resources = arns.map { |pattern| "#{" " * 20}- !Sub \"#{SECRET_ARN}#{pattern}\"\n" }.join
            template("writable-secrets.yaml.tmpl", "RESOURCES" => resources.chomp).chomp
          end

          private

          def s3_rows(buckets)
            rows = s3_read_rows(buckets.flat_map { |b| [s3_arn(b.name), s3_arn("#{b.name}/*")] })
            writes = buckets.select(&:write).map { |b| s3_arn("#{b.name}/*") }
            writes.empty? ? rows : rows + s3_write_rows(writes)
          end

          def s3_arn(path) = "arn:${AWS::Partition}:s3:::#{path}"
        end
      end
    end
  end
end
