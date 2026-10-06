module Hecks
  module Projections
    module Deploy
      module Box
        # The two CloudFormation stacks of a box deploy, and the pieces spliced into them. Mixed
        # into `Box`, which supplies `template`, the access statements and the constants.
        module StackYaml
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the database stack
          def rds_yaml(plan)
            template("rds.yaml.tmpl", "STACK" => plan.infra_name, "DB_CLASS" => plan.database_class,
                                      "STORAGE_GB" => plan.storage_gb.to_s, "DB_NAME" => plan.database_name,
                                      "ENGINE_VERSION" => plan.engine_version, "BACKUP_DAYS" => plan.backup_days.to_s)
          end

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated region
          # @return [String] the box stack
          def box_yaml(plan, region)
            template("box.yaml.tmpl",
                     "STACK" => plan.infra_name, "INSTANCE_TYPE" => plan.instance_type,
                     "VOLUME_GB" => plan.volume_gb.to_s, "SNAPSHOTS_KEEP" => plan.snapshots_keep.to_s,
                     "AMI_PARAMETER" => ami_parameter(plan.instance_type),
                     "COMPUTE_DOMAIN" => compute_domain(region),
                     "SECRET_RESOURCES" => secret_resources(plan), "WRITABLE_SECRETS" => writable_secrets(plan),
                     "TUNNEL_EGRESS" => tunnel_egress(plan),
                     "SWAP_COMMANDS" => swap_commands(plan), "ECR_REPOSITORIES" => ecr_repositories(plan),
                     "ECR_OUTPUTS" => ecr_outputs(plan), "S3_POLICY" => s3_policy(plan))
          end

          # Graviton families end their generation digit with `g` (`t4g`, `m7gd`, `c6gn`).
          #
          # @param instance_type [String] an EC2 instance type
          # @return [String] the SSM parameter of the matching Amazon Linux image
          def ami_parameter(instance_type)
            arch = instance_type.split(".").first.match?(/\d+g[a-z]*\z/) ? "arm64" : "x86_64"
            "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-#{arch}"
          end

          # @param region [String] the AWS region
          # @return [String] the DNS suffix an Elastic address's public name ends with
          def compute_domain(region)
            region == LEGACY_COMPUTE_REGION ? "compute-1.amazonaws.com" : "#{region}.compute.amazonaws.com"
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the outbound rules a Cloudflare Tunnel sidecar needs, or nothing
          def tunnel_egress(plan)
            return "" unless plan.tunnel

            template("tunnel-egress.yaml.tmpl", {})
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the user-data lines that add swap, or nothing when `swap_gb` is 0
          def swap_commands(plan)
            return "" if plan.swap_gb.zero?

            pad = " " * 10
            <<~SH.lines.map { |line| "#{pad}#{line}" }.join
              # swap so a memory spike at boot cannot take the box down
              fallocate -l #{plan.swap_gb}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
              echo '/swapfile none swap sw 0 0' >> /etc/fstab
            SH
          end

          # One ECR repository per container, keeping the newest 30 images. A task definition names
          # images that already have repositories, so none are made.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] CloudFormation resources, each preceded by a blank line
          def ecr_repositories(plan)
            return "" if plan.task_definition

            plan.containers.map do |container|
              ecr_repository(container).lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
            end.join.chomp
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] one repository URI output per container
          def ecr_outputs(plan)
            return "" if plan.task_definition

            plan.containers.map do |container|
              id = logical(container.name)
              "  #{id}RepositoryUri:\n    Value: !GetAtt #{id}Repository.RepositoryUri\n"
            end.join.chomp
          end

          # @param name [String] a container name such as `web-app`
          # @return [String] a CloudFormation logical id fragment, such as `WebApp`
          def logical(name)
            name.split("-").map(&:capitalize).join
          end

          private

          def ecr_repository(container)
            template("ecr-repository.yaml.tmpl", "ID"         => "#{logical(container.name)}Repository",
                                                 "REPOSITORY" => container.repository)
          end
        end
      end
    end
  end
end
