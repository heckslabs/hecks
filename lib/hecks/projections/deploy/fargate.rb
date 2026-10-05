require_relative "../../projector"
require_relative "shared"
require_relative "scripts"
require_relative "preview"
require_relative "fargate/settings"
require_relative "fargate/assembly"

module Hecks
  module Projections
    module Deploy
      # The AWS Fargate deploy target for `deployed_to("AwsFargate")`: renders a
      # CloudFormation stack (ECR, ECS, ALB, CloudFront) plus the shared VPC/RDS `Shared` builds.
      module Fargate
        extend Projector::Target

        projects_as :aws_fargate, needs_world: true, emits: :files

        module_function

        # Generates `template.yaml`, `Makefile`, `Dockerfile`, and — unless
        # this domain borrows another domain's RDS instance — `bastion.yaml`.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options; same shape as `Lambda.call`'s
        # @return [Hash{String => String}] the generated file contents, keyed by filename
        # @raise [ArgumentError] if the domain's deploy settings conflict
        def call(bluebook:, options: {})
          world                 = options.fetch(:world)
          domain                = options.fetch(:domain_dir)
          root                  = options.fetch(:root)
          world_file            = options.fetch(:world_file)
          cross_domain_registry = options.fetch(:cross_domain_registry)
          tenant_options        = options[:tenant] || {}

          domain_name          = File.basename(domain)
          declared_domain_name = world.domain

          deploy_settings = world.for_verb("deployed_to")

          # Same tenant override `Lambda.call` applies; see that method's comment.
          if tenant_options[:tenant]
            base_stack_name = deploy_settings[:stack_name] || domain_name
            deploy_settings = deploy_settings.merge(stack_name: "#{base_stack_name}-#{tenant_options[:tenant]}",
                                                     schema: tenant_options[:schema] || tenant_options[:tenant])
          end

          infra_name = deploy_settings[:stack_name] || domain_name
          db_name    = infra_name.gsub(/[^a-zA-Z0-9]/, "")

          # Validated the same way `Lambda.call` validates its own target —
          # `deploy.bluebook`'s own `FargateTarget.Declare`, not a
          # hand-checked `fetch(:cpu) { raise ... }` chain.
          deploy_dispatcher = Hecks.boot(File.expand_path("../../deploy", __dir__))
          begin
            target = deploy_dispatcher.dispatch(
              "Deploy::FargateTarget.Declare",
              with: {
                domain:   { value: declared_domain_name },
                region:   { value: deploy_settings[:region] },
                cpu:      { value: deploy_settings.fetch(:cpu, 256) },
                memory:   { value: deploy_settings.fetch(:memory, 512) },
                database: { value: deploy_settings.fetch(:database, "Postgres") },
                web:      { value: deploy_settings.fetch(:web, "None") },
                port:     { value: deploy_settings.fetch(:port, 8080) }
              }
            ).instance
          rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsFargate\") is invalid: #{e.message}"
          end

          region   = target.state[:region].value
          cpu      = target.state[:cpu].value
          memory   = target.state[:memory].value
          database = target.state[:database].value
          port     = target.state[:port].value
          aurora   = database == "Aurora"
          shared   = database == "Shared"
          rust_web = target.state[:web].value == "Rust"
          # Same `.env.local` convention `Lambda` uses; `make sync-google-oauth`
          # owns the secret's lifecycle. Fargate only declares
          # GOOGLE_OAUTH_SECRET_ID — the secret itself is never a stack resource.
          google_oauth_present = rust_web &&
                                 File.exist?(File.join(domain, ".env.local")) &&
                                 File.read(File.join(domain, ".env.local")).match?(/^GOOGLE_CLIENT_ID=\S/)

          # Every policy in every loaded chapter — see `Lambda.call`'s own
          # comment on why this reads the whole registry, not only this
          # domain's own top-level list.
          cross_domain_fargate_targets = cross_domain_registry.bluebooks.flat_map { |_name, chapter|
            chapter.policies.select(&:target_domain).map(&:target_domain)
          }.uniq.sort

          # Same "Shared" borrowing `Lambda.call` supports; see that method's
          # comment. `owner`/`owner_stack` stay plain `deploy_settings` reads,
          # never validated attributes — ownership is a deploy-time wiring fact.
          if shared
            owner_domain_name = deploy_settings[:owner] or raise ArgumentError, <<~MSG
              #{world_file}'s deployed_to("AwsFargate") declares database "Shared" but no owner. Add one, e.g.:

                  deployed_to("AwsFargate") do
                    ...
                    database "Shared"
                    owner "Core"
                  end

              naming the already-deployed domain whose Postgres instance this one borrows.
            MSG
            owner_stack_name = deploy_settings[:owner_stack] || "hecks-#{owner_domain_name.downcase}"
            owner_db_name     = owner_domain_name.downcase
          end

          hecks_schema = shared ? infra_name : deploy_settings[:schema]

          # `infra_name` is already alphanumeric-only + hyphen-friendly for
          # CloudFormation's own logical-id character set, matching
          # `Lambda.call`'s own `logical_id` convention.
          logical_id     = "#{infra_name.split(/[_-]/).map(&:capitalize).join}Service"
          stack_prefix   = deploy_settings[:stack_prefix] || "hecks"
          stack_name     = "#{stack_prefix}-#{infra_name}"
          desired_count  = deploy_settings.fetch(:desired_count, 1)

          # Every optional setting, checked; a world that sets none resolves to the
          # derived ids and names the generator has always used.
          begin
            plan = Settings.resolve(
              deploy_settings,
              infra_name: infra_name, logical_id: logical_id, db_id: "#{logical_id.sub(/Service\z/, '')}Db",
              stack_name: stack_name, port: port, shared: shared
            )
          rescue ArgumentError => e
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsFargate\"): #{e.message}"
          end
          ids    = plan.ids
          names  = plan.names
          layout = plan.layout

          db_id             = ids[:database_prefix]
          db_ref_id         = aurora ? "#{db_id}Cluster" : db_id
          secret_sub        = aurora ? "#{db_id}Secret" : "#{db_ref_id}.MasterUserSecret.SecretArn"
          secret_intrinsic  = aurora ? "!Ref #{db_id}Secret" : "!GetAtt #{db_ref_id}.MasterUserSecret.SecretArn"
          db_secret_ref     = shared ? "OwningDatabaseSecretArn" : secret_sub

          # Always true here: unlike Lambda's opt-in NAT Gateway, a Fargate task
          # always needs internet-facing infra (ALB ingress, ECR/Logs/Secrets
          # egress), so `Shared.vpc_and_database_yaml`'s NAT Gateway is unconditional.
          network_needs_internet = true

          # Never created when `shared` — this domain's own VPC (and its compute
          # security group) is skipped entirely; the task and ALB-ingress rule
          # reach through the borrowed owner's security group instead.
          compute_security_group_ref = shared ? "!Ref OwningSecurityGroupId" : "!Ref #{ids[:compute_prefix]}SecurityGroup"

          # `logical_id` stays the derived name in prose (descriptions, comments);
          # the ids below are what the resources are actually declared with, which
          # the world's `logical_ids` setting may replace.
          service_id         = ids[:service]
          ecr_repository_id  = ids[:ecr_repository]
          cluster_id         = ids[:cluster]
          task_definition_id = ids[:task_definition]
          execution_role_id  = ids[:execution_role]
          task_role_id       = ids[:task_role]
          log_group_id       = ids[:log_group]
          target_group_id    = ids[:target_group]
          alb_id             = ids[:alb]
          alb_sg_id          = ids[:alb_security_group]
          listener_id        = ids[:listener]
          distribution_id    = ids[:distribution]
          session_secret_id  = ids[:session_secret]
          domain_container   = layout.domain
          alb_sg_description = names[:alb_security_group_description] ||
                               "#{alb_sg_id} - HTTP ingress from CloudFront only, forwarded to #{logical_id} only"
          port_range         = Containers.port_range(layout)
          vpc_ref            = shared ? "!Ref OwningVpcId" : "!Ref #{db_id}Vpc"
          sidecar_dir        = plan.install_dir
          db_name_ref        = plan.db_name_parameter ? "!Ref #{plan.db_name_parameter}" : nil

          stack_outputs = Shared.stack_outputs(
            shared: shared, db_id: db_id, db_ref_id: db_ref_id, secret_intrinsic: secret_intrinsic,
            compute_security_group_ref: compute_security_group_ref, google_oauth_present: network_needs_internet
          )
          bastion_parameters = Shared.bastion_parameters(shared: shared, google_oauth_present: network_needs_internet)
          Shared.check_bastion_parameters!(bastion_parameters, stack_outputs)

          always_params_yaml = <<~ALWAYSPARAMS.rstrip
            #{domain_container.tag_parameter}:
              Type: String
              Default: latest
              Description: ECR image tag this task pulls — never hardcode latest in the TaskDefinition; a first deploy and a later rollout share this one parameter.
          ALWAYSPARAMS
          oauth_params_yaml = google_oauth_present ? <<~OAUTHPARAMS.rstrip : ""
            # Same chicken-egg as Lambda's WebRedirectBaseUrl — CloudFront's
            # hostname does not exist until this stack does. Empty on a true
            # first deploy; `make deploy` looks up Outputs.CloudFrontDomain
            # after and self-heals.
            WebRedirectBaseUrl:
              Type: String
              Default: ""
          OAUTHPARAMS
          # Built outside the heredoc so re-indenting the template can't shift
          # this YAML out of sync with SessionSecretRead/env — same pattern
          # as `Lambda`'s own `OAUTHPOLICY`.
          oauth_task_policy_yaml = google_oauth_present ? <<~OAUTHPOLICY.rstrip : ""
            - PolicyName: GoogleOauthSecretRead
              PolicyDocument:
                Version: '2012-10-17'
                Statement:
                  - Effect: Allow
                    Action: secretsmanager:GetSecretValue
                    Resource: !Sub "arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:#{stack_name}-web-google-oauth-*"
          OAUTHPOLICY
          oauth_task_env_yaml = google_oauth_present ? <<~OAUTHENV.rstrip : ""
            - Name: GOOGLE_OAUTH_SECRET_ID
              Value: #{stack_name}-web-google-oauth
            - Name: GOOGLE_REDIRECT_URI
              Value: !Sub "${WebRedirectBaseUrl}/auth/google/callback"
          OAUTHENV
          owning_params_yaml = shared ? <<~SHAREDPARAMS.rstrip : ""
            # The storehouse — #{owner_domain_name}'s own live stack Outputs,
            # looked up at deploy time (the generated Makefile's own `deploy:`
            # target) via `aws cloudformation describe-stacks`, the identical
            # pattern `Lambda`'s own generated Makefile already uses for a
            # Shared-mode domain.
            OwningVpcId:
              Type: AWS::EC2::VPC::Id
            OwningSubnetAId:
              Type: AWS::EC2::Subnet::Id
            OwningSubnetBId:
              Type: AWS::EC2::Subnet::Id
            # PUBLIC subnets, NOT OwningSubnetAId/OwningSubnetBId above — a
            # real, live deploy (a shared-database stack) found the ALB placed in
            # the private pair creates successfully and reports its target
            # health as healthy (health checks run from inside the VPC), yet
            # is completely unreachable from outside it:
            # OwningSubnetAId/OwningSubnetBId have MapPublicIpOnLaunch: false
            # and no Internet Gateway route. These two — resolved from the
            # owner stack's own PublicSubnetId/BastionSubnetId Outputs,
            # MapPublicIpOnLaunch: true with a real 0.0.0.0/0 -> igw route —
            # are the pair that actually works for an internet-facing ALB.
            # Service.NetworkConfiguration below still (correctly) uses the
            # private pair for the tasks themselves — only the ALB moves.
            OwningPublicSubnetAId:
              Type: AWS::EC2::Subnet::Id
            OwningPublicSubnetBId:
              Type: AWS::EC2::Subnet::Id
            OwningSecurityGroupId:
              Type: AWS::EC2::SecurityGroup::Id
            OwningDatabaseEndpoint:
              Type: String
            OwningDatabaseSecretArn:
              Type: String
          SHAREDPARAMS
          extra_params_yaml = Settings.parameters_yaml(plan, default_count: desired_count, shared_db_name: owner_db_name).rstrip
          parameters_yaml = [always_params_yaml, oauth_params_yaml, owning_params_yaml, extra_params_yaml].reject(&:empty?).join("\n")

          template_yaml = <<~YAML
            # GENERATED by hecks deploy project #{domain} — re-run it to refresh
            # this file rather than hand-editing. Source: #{world_file}'s own
            # deployed_to("AwsFargate") block.
            #
            # Plain CloudFormation, not SAM — deployed with
            # `aws cloudformation deploy`, never `sam deploy`. Self-contained
            # the same way `Lambda`'s own template is: this stack owns its own
            # private VPC, subnets, and RDS Postgres instance (unless
            # database "Shared"), not just the ECS service.
            AWSTemplateFormatVersion: '2010-09-09'
            Description: >
              #{infra_name} — dispatched through hecks's rust/host, running as a
              long-lived container on AWS Fargate, backed by its own private RDS
              Postgres instance.
            #{parameters_yaml.empty? ? "" : "Parameters:\n" + parameters_yaml.each_line.map { |l| "  #{l}" }.join}
            Resources:
              #{shared ? "" : Shared.vpc_and_database_yaml(
                db_id: db_id, db_name: db_name, infra_name: infra_name, aurora: aurora,
                google_oauth_present: network_needs_internet, compute_logical_id: ids[:compute_prefix],
                compute_description: "#{logical_id} - inbound from #{alb_sg_id} only, egress rules attached separately below"
              ).each_line.with_index.map { |l, i| (i.zero? ? "" : "  ") + l }.join.rstrip}

              #{alb_sg_id}:
                Type: AWS::EC2::SecurityGroup
                Properties:
                  VpcId: #{vpc_ref}
                  GroupDescription: #{alb_sg_description}
                  SecurityGroupIngress:
                    # pl-3b927c52 — com.amazonaws.global.cloudfront.origin-
                    # facing, AWS's own global, account-agnostic managed
                    # prefix list (confirmed: `aws ec2 describe-managed-
                    # prefix-lists`, OwnerId "AWS", same id in every
                    # account/region). NOT 0.0.0.0/0 — the whole reason
                    # #{distribution_id} above exists is Managed-
                    # CachingDisabled on every session-cookie-driven
                    # route; leaving the ALB itself open to the public
                    # internet on this same port would let anyone bypass
                    # that distribution (and its HTTPS) entirely and hit
                    # the plain-HTTP origin directly — the exact gap a
                    # code review caught the first time this resource was
                    # added.
                    - IpProtocol: tcp
                      FromPort: 80
                      ToPort: 80
                      SourcePrefixListId: pl-3b927c52

              #{ids[:ingress_from_alb]}:
                Type: AWS::EC2::SecurityGroupIngress
                Properties:
                  GroupId: #{compute_security_group_ref}
                  IpProtocol: tcp
                  FromPort: #{port_range.min}
                  ToPort: #{port_range.max}
                  SourceSecurityGroupId: !Ref #{alb_sg_id}

              #{ecr_repository_id}:
                Type: AWS::ECR::Repository
                Properties:
                  RepositoryName: #{domain_container.repository_name}
                  ImageScanningConfiguration:
                    ScanOnPush: true

              #{cluster_id}:
                Type: AWS::ECS::Cluster
                Properties:
                  ClusterName: #{names[:cluster]}

              #{log_group_id}:
                Type: AWS::Logs::LogGroup
                Properties:
                  LogGroupName: #{names[:log_group]}
                  RetentionInDays: 30

              # Always minted — HECKS_SERVE_MODE always runs web.rs, which
              # panics on an empty SESSION_SECRET (seen live as a 502
              # after a database cutover). rust/host fetches this at cold
              # start (secrets.rs), never a plain env var.
              #{session_secret_id}:
                Type: AWS::SecretsManager::Secret
                Properties:
                  # TMPL:session_secret_properties
                  GenerateSecretString:
                    SecretStringTemplate: '{}'
                    GenerateStringKey: session_secret
                    PasswordLength: 64
                    ExcludePunctuation: true

              # Pulls the image and writes CloudWatch Logs — AWS's own managed
              # AmazonECSTaskExecutionRolePolicy already covers both (ECR auth
              # + GetDownloadUrlForLayer, and logs:CreateLogStream/PutLogEvents);
              # the one grant that policy does NOT cover is fetching this
              # domain's own database secret, added below, least-privilege,
              # scoped to the single secret ARN this stack itself depends on.
              #{execution_role_id}:
                Type: AWS::IAM::Role
                Properties:
                  AssumeRolePolicyDocument:
                    Version: '2012-10-17'
                    Statement:
                      - Effect: Allow
                        Principal: { Service: ecs-tasks.amazonaws.com }
                        Action: sts:AssumeRole
                  ManagedPolicyArns:
                    - arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
                  Policies:
                    # TMPL:execution_database_grant
                    # TMPL:extra_execution_policies

              # The container's OWN runtime permissions — rust/host fetches
              # DB_SECRET_ARN itself, over the AWS SDK, the same "never let
              # CloudFormation/ECS configuration see it resolved" posture
              # `Lambda`'s own generated template already holds to (a
              # `Secrets:` ContainerDefinition property would resolve it
              # into a plain environment variable instead).
              #{task_role_id}:
                Type: AWS::IAM::Role
                Properties:
                  AssumeRolePolicyDocument:
                    Version: '2012-10-17'
                    Statement:
                      - Effect: Allow
                        Principal: { Service: ecs-tasks.amazonaws.com }
                        Action: sts:AssumeRole
                  Policies:
                    - PolicyName: #{names[:db_secret_policy]}
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Sub "${#{db_secret_ref}}"
                    - PolicyName: SessionSecretRead
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Ref #{session_secret_id}
                    #{oauth_task_policy_yaml.empty? ? "" : "# TMPL:oauth_task_policy"}
                    # TMPL:cross_domain_fargate_policies
                    # TMPL:extra_task_policies

              #{task_definition_id}:
                Type: AWS::ECS::TaskDefinition
                Properties:
                  Family: #{names[:family]}
                  RequiresCompatibilities: [FARGATE]
                  NetworkMode: awsvpc
                  # ARM64, not Fargate's own x86_64 default — matching the
                  # generated Makefile's own aarch64-unknown-linux-gnu build
                  # (below) and Lambda's own arm64 toolchain this reuses; a
                  # container built for the wrong arch fails at task start,
                  # not at build time, so this has to agree with the image
                  # docker-build actually pushes.
                  RuntimePlatform:
                    CpuArchitecture: ARM64
                    OperatingSystemFamily: LINUX
                  Cpu: "#{cpu}"
                  Memory: "#{memory}"
                  ExecutionRoleArn: !GetAtt #{execution_role_id}.Arn
                  TaskRoleArn: !GetAtt #{task_role_id}.Arn
                  ContainerDefinitions:
                    - Name: #{domain_container.name}
                      Image: !Sub "${#{ecr_repository_id}.RepositoryUri}:${#{domain_container.tag_parameter}}"
                      # TMPL:domain_essential
                      PortMappings:
                        - ContainerPort: #{port}
                      LogConfiguration:
                        LogDriver: awslogs
                        Options:
                          awslogs-group: !Ref #{log_group_id}
                          awslogs-region: !Ref AWS::Region
                          awslogs-stream-prefix: #{domain_container.name}
                      Environment:
                        - Name: HECKS_DOMAIN
                          Value: #{declared_domain_name}
                        - Name: HECKS_ERA
                          Value: "1"
                        - Name: PORT
                          Value: "#{port}"
                        # `rust/host/src/server.rs`'s own top-of-`main`
                        # switch — without it, this container runs as the
                        # Lambda custom-runtime process `Lambda`'s own
                        # generated binary always has, which blocks
                        # forever polling a Runtime API that doesn't exist
                        # here, never answering the health check or
                        # anything else on `port`.
                        - Name: HECKS_SERVE_MODE
                          Value: "1"
                        # `web "Rust"` vs `web "None"` is otherwise inert
                        # here today — both modes generate the identical
                        # task/service/target-group shape, since a Fargate
                        # task always answers HTTP on `port` for dispatch
                        # requests either way. Passed through so
                        # `rust/host`'s own server loop (server.rs) can
                        # read it and decide whether to also serve the
                        # public web UI in-process, the same `web`-shaped
                        # choice `Lambda`'s own `rust_web` already makes
                        # for the Lambda path.
                        - Name: HECKS_WEB
                          Value: #{target.state[:web].value}
                        # HECKS_WASM_PATH/HECKS_IR_PATH — main.rs requires
                        # both unconditionally at boot (ir::ir().ok_or(...)?,
                        # no fallback, and HECKS_WASM_PATH for every
                        # dispatch) regardless of `web`/HECKS_SERVE_MODE. A
                        # container built with neither set crashes before
                        # ever reaching its own serve loop — found live
                        # deploying a real domain container, fixed here so every Fargate domain ships
                        # both sidecars by default. Paths match the
                        # Dockerfile's own COPY destinations, below.
                        - Name: HECKS_WASM_PATH
                          Value: #{sidecar_dir}/#{domain_name}.wasm
                        - Name: HECKS_IR_PATH
                          Value: #{sidecar_dir}/#{domain_name}.ir.json
                        - Name: SESSION_SECRET_ARN
                          Value: !Ref #{session_secret_id}
                        - Name: HECKS_CHECKOUT_DOMAIN
                          Value: #{declared_domain_name}
                        #{oauth_task_env_yaml.empty? ? "" : "# TMPL:oauth_task_env"}
                        # TMPL:db_env
                        # TMPL:domain_env
                    # TMPL:extra_containers

              #{target_group_id}:
                Type: AWS::ElasticLoadBalancingV2::TargetGroup
                Properties:
                  TargetType: ip
                  Port: #{port}
                  Protocol: HTTP
                  VpcId: #{vpc_ref}
                  HealthCheckPath: #{domain_container.health_path}
                  HealthCheckPort: "#{port}"
                  # TMPL:target_group_attributes

              #{alb_id}:
                Type: AWS::ElasticLoadBalancingV2::LoadBalancer
                Properties:
                  Name: #{names[:alb]}
                  Scheme: internet-facing
                  Type: application
                  SecurityGroups: [!Ref #{alb_sg_id}]
                  Subnets: #{shared ? "[!Ref OwningPublicSubnetAId, !Ref OwningPublicSubnetBId]" : "[!Ref #{db_id}PublicSubnet, !Ref #{db_id}BastionPublicSubnet]"}

              #{listener_id}:
                Type: AWS::ElasticLoadBalancingV2::Listener
                Properties:
                  LoadBalancerArn: !Ref #{alb_id}
                  Port: 80
                  Protocol: HTTP
                  DefaultActions:
                    - Type: forward
                      TargetGroupArn: !Ref #{layout.default.target_group_id}

              # TMPL:extra_target_groups
              #{service_id}:
                Type: AWS::ECS::Service
                DependsOn: #{Containers.depends_on(layout, listener_id)}
                Properties:
                  ServiceName: #{names[:service]}
                  Cluster: !Ref #{cluster_id}
                  TaskDefinition: !Ref #{task_definition_id}
                  DesiredCount: #{plan.desired_count_parameter ? "!Ref #{plan.desired_count_parameter}" : desired_count}
                  LaunchType: FARGATE
                  # TMPL:service_tuning
                  NetworkConfiguration:
                    AwsvpcConfiguration:
                      AssignPublicIp: DISABLED
                      Subnets: #{shared ? "[!Ref OwningSubnetAId, !Ref OwningSubnetBId]" : "[!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]"}
                      SecurityGroups: [#{compute_security_group_ref}]
                  LoadBalancers:
                    - ContainerName: #{domain_container.name}
                      ContainerPort: #{port}
                      TargetGroupArn: !Ref #{target_group_id}
                    # TMPL:extra_load_balancers

              # TMPL:distribution

              # TMPL:extra_resources
            Outputs:
              ServiceUrl:
                Value: !Sub "http://${#{alb_id}.DNSName}"
              CloudFrontDomain:
                Value: !GetAtt #{distribution_id}.DomainName
              #{stack_outputs.map { |o| "#{o[:key]}:\n    Value: #{o[:ref]}" }.join("\n  ")}
              # TMPL:extra_outputs
          YAML

          # Spliced in after the heredoc renders, not interpolated inside it —
          # `<<~` dedents from raw source before `#{...}` evaluates, so a
          # multi-line value can't be reindented a second time by the heredoc.
          template_yaml = template_yaml.sub(/^([ \t]*)# TMPL:db_env\n/) { db_env_yaml(shared: shared, owner_db_name: owner_db_name, db_ref_id: db_ref_id, db_name: db_name, secret_sub: secret_sub, hecks_schema: hecks_schema, db_name_ref: db_name_ref, base: $1) }
          # Indented by the marker's own rendered column, never a hand-computed
          # one — the heredoc dedents after interpolation, so a source-counted
          # column lands at the wrong depth.
          template_yaml = Yaml.splice(template_yaml, "oauth_task_policy", "#{oauth_task_policy_yaml}\n")
          template_yaml = Yaml.splice(template_yaml, "oauth_task_env", "#{oauth_task_env_yaml}\n")
          template_yaml = template_yaml.sub(/^([ \t]*)# TMPL:cross_domain_fargate_policies\n/) {
            cross_domain_fargate_targets.empty? ? "" : cross_domain_fargate_policy_yaml(cross_domain_fargate_targets, $1)
          }

          begin
            template_yaml = Assembly.apply(
              template_yaml, plan,
              stack_name: stack_name, vpc_ref: vpc_ref, listener_id: listener_id, alb_id: alb_id, distribution_id: distribution_id,
              db_secret_ref: db_secret_ref
            )
          rescue ArgumentError => e
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsFargate\"): #{e.message}"
          end

          bastion_yaml = shared ? nil : Shared.bastion_yaml(
            domain: domain, infra_name: infra_name, stack_name: stack_name, db_id: db_id,
            google_oauth_present: network_needs_internet, bastion_parameters: bastion_parameters
          )

          dockerfile = <<~DOCKERFILE
            # GENERATED by hecks deploy project #{domain} — re-run it to refresh this
            # file rather than hand-editing. Modeled on a Ruby deployment's own
            # Dockerfile shape: build the binary outside the image (this directory's own
            # Makefile, before `docker build` runs), ship only the result — one COPY,
            # not a from-scratch toolchain install on every deploy.
            FROM debian:bookworm-slim

            # ca-certificates — real outbound TLS (Secrets Manager, any third-party
            # API this domain calls) needs a real system CA bundle.
            # libpq5 — Adapters::PostgresEra's own native `tokio_postgres`/libpq
            # linkage needs the actual shared library present at runtime, the same
            # reason Lambda's own generated Makefile patches libpq.so onto that
            # package's Ruby-side equivalent.
            RUN apt-get update -qq && apt-get install -y --no-install-recommends -qq ca-certificates libpq5 \\
                && rm -rf /var/lib/apt/lists/*

            COPY #{plan.build_context_dir}#{domain_name}-host #{sidecar_dir}/#{domain_name}-host
            # The .wasm/.ir.json sidecars main.rs requires at boot —
            # HECKS_WASM_PATH/HECKS_IR_PATH (template.yaml's own
            # ContainerDefinitions Environment) point at these exact paths.
            COPY #{plan.build_context_dir}#{domain_name}.wasm #{sidecar_dir}/#{domain_name}.wasm
            COPY #{plan.build_context_dir}#{domain_name}.ir.json #{sidecar_dir}/#{domain_name}.ir.json

            ENV PORT=#{port}
            ENV BIND=0.0.0.0
            EXPOSE #{port}

            CMD ["#{sidecar_dir == Settings::DEFAULT_INSTALL_DIR ? domain_name : "#{sidecar_dir}/#{domain_name}"}-host"]
          DOCKERFILE

          makefile_content = <<~MAKE
            # GENERATED by hecks deploy project #{domain} — re-run it to refresh
            # this file rather than hand-editing.
            #
            # `make deploy` — builds rust/host for this domain, pushes it to this
            # stack's own ECR repository, and deploys the CloudFormation stack.
            # No SAM anywhere in this path.

            ROOT       := #{root}
            DOMAIN     := #{domain}
            STACK      := #{stack_name}
            BASTION_STACK := #{stack_name}-bastion
            REGION     := #{region}
            IMAGE_TAG  := latest

            build:
            # aarch64, not x86_64 — matches template.yaml's own
            # RuntimePlatform: ARM64 (this Makefile has to build the same
            # architecture the task definition declares, or the container
            # fails at task start, not at build time), and reuses the same
            # working aarch64-unknown-linux-gnu toolchain the Lambda deploy
            # path already depends on, rather than standing up a second,
            # x86_64-only one.
            \t@rustup target list --installed 2>/dev/null | grep -qx aarch64-unknown-linux-gnu || rustup target add aarch64-unknown-linux-gnu
            # GNU cross-linker, not Apple clang — rustc's aarch64-unknown-linux-gnu
            # target emits `-Wl,--fix-cortex-a53-843419`, which macOS ld rejects
            # (found live building a domain image). Same
            # toolchain Lambda's generated Makefile already documents.
            \t@command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || { echo "aarch64-linux-gnu-gcc isn't on PATH. Install once with: brew tap messense/macos-cross-toolchains && brew install aarch64-unknown-linux-gnu"; exit 1; }
            # The .wasm/.ir.json sidecars main.rs requires at boot,
            # unconditionally — see template.yaml's own HECKS_WASM_PATH/
            # HECKS_IR_PATH comment for why. `hecks build_wasm` is the same
            # generator the Lambda deploy path already uses to produce
            # rust/dist/#{domain_name}.wasm/.ir.json from this domain's own
            # .bluebook.
            \tcd $(ROOT) && HECKS_ENVIRONMENT=memory ruby exe/hecks build.build_wasm domain=$(DOMAIN) --wait
            \tcd $(ROOT)/rust/host && CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc rustup run stable cargo build --release --target aarch64-unknown-linux-gnu --bin bootstrap
            \tcp $(ROOT)/rust/host/target/aarch64-unknown-linux-gnu/release/bootstrap #{domain_name}-host
            \tcp $(ROOT)/rust/dist/#{domain_name}.wasm #{domain_name}.wasm
            \tcp $(ROOT)/rust/dist/#{domain_name}.ir.json #{domain_name}.ir.json

            .PHONY: ecr-login
            ecr-login:
            \taws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(REGION).amazonaws.com

            .PHONY: docker-build
            docker-build: build
            # linux/arm64, not the generator's old amd64 default — has to
            # match RuntimePlatform/the binary this Makefile's own build:
            # step just cross-compiled, above.
            \tdocker build --platform linux/arm64 -t #{domain_container.repository_name}:$(IMAGE_TAG) .

            .PHONY: docker-push
            docker-push: ecr-login
            \tACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \\
            \t\tdocker tag #{domain_container.repository_name}:$(IMAGE_TAG) $$ACCOUNT_ID.dkr.ecr.$(REGION).amazonaws.com/#{domain_container.repository_name}:$(IMAGE_TAG); \\
            \t\tdocker push $$ACCOUNT_ID.dkr.ecr.$(REGION).amazonaws.com/#{domain_container.repository_name}:$(IMAGE_TAG)

            .PHONY: deploy
            deploy: docker-build docker-push
            #{shared ? "\t@echo \"Looking up #{owner_stack_name}'s shared VpcId/PrivateSubnetAId/PrivateSubnetBId/PublicSubnetId/BastionSubnetId/FunctionSecurityGroupId/DatabaseEndpoint/DatabaseSecretArn outputs to pass as $(STACK)'s Owning* parameters...\"\n\tOWNER_VPC_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue\" --output text); \\\n\t\tOWNER_SUBNET_A_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='PrivateSubnetAId'].OutputValue\" --output text); \\\n\t\tOWNER_SUBNET_B_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='PrivateSubnetBId'].OutputValue\" --output text); \\\n\t\tOWNER_PUBLIC_SUBNET_A_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='PublicSubnetId'].OutputValue\" --output text); \\\n\t\tOWNER_PUBLIC_SUBNET_B_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='BastionSubnetId'].OutputValue\" --output text); \\\n\t\tOWNER_SG_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='FunctionSecurityGroupId'].OutputValue\" --output text); \\\n\t\tOWNER_DB_HOST=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='DatabaseEndpoint'].OutputValue\" --output text); \\\n\t\tOWNER_DB_SECRET_ARN=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='DatabaseSecretArn'].OutputValue\" --output text); \\\n\t\taws cloudformation deploy --template-file template.yaml --stack-name $(STACK) --region $(REGION) --capabilities CAPABILITY_IAM \\\n\t\t\t--parameter-overrides #{domain_container.tag_parameter}=$(IMAGE_TAG) OwningVpcId=$$OWNER_VPC_ID OwningSubnetAId=$$OWNER_SUBNET_A_ID OwningSubnetBId=$$OWNER_SUBNET_B_ID OwningPublicSubnetAId=$$OWNER_PUBLIC_SUBNET_A_ID OwningPublicSubnetBId=$$OWNER_PUBLIC_SUBNET_B_ID OwningSecurityGroupId=$$OWNER_SG_ID OwningDatabaseEndpoint=$$OWNER_DB_HOST OwningDatabaseSecretArn=$$OWNER_DB_SECRET_ARN" : "\taws cloudformation deploy --template-file template.yaml --stack-name $(STACK) --region $(REGION) --capabilities CAPABILITY_IAM --parameter-overrides #{domain_container.tag_parameter}=$(IMAGE_TAG)"}
            \t$(MAKE) mint-era

            #{shared ? <<~SHAREDMINT.rstrip : <<~OWNMINT.rstrip
              # mint-era isn't automated yet for a Shared-mode domain (database
              # "Shared") — see #{owner_domain_name}'s own deploy directory for
              # the manual tunnel path. Exits 0 (not 1) so a genuinely successful
              # `make deploy` still reports success.
              .PHONY: mint-era
              mint-era:
              \t@echo "mint-era isn't automated yet for a Shared-mode domain (database \\"Shared\\") -- see #{owner_domain_name}'s own deploy directory's tunnel path. This is NOT a failure."; \\
              \texit 0
              SHAREDMINT
              # `make mint-era` — the same bastion/tunnel/retry/teardown chain
              # `Lambda`'s own generated Makefile uses (this directory's own
              # bastion.yaml, stood up and torn down for the one boot that mints
              # era 1), against this stack's own VPC/RDS instead of a Lambda's.
              .PHONY: mint-era
              mint-era:
              \t@echo "Looking up $(STACK)'s VPC/security group..."
              \t#{stack_outputs.map { |o| %($(eval #{o[:var]} := $(shell aws cloudformation describe-stacks --stack-name $(STACK) --query "Stacks[0].Outputs[?OutputKey=='#{o[:key]}'].OutputValue" --output text))) }.join("\n\t")}
              \t@echo "Deploying the temporary bastion stack $(BASTION_STACK)..."
              \taws cloudformation deploy --template-file bastion.yaml --stack-name $(BASTION_STACK) \\
              \t\t--parameter-overrides #{bastion_parameters.map { |p| "#{p[:name]}=$(#{stack_outputs.find { |o| o[:key] == p[:from_output] }[:var]})" }.join(" ")} \\
              \t\t--capabilities CAPABILITY_IAM
              \t@INSTANCE_ID=$$(aws cloudformation describe-stacks --stack-name $(BASTION_STACK) --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text); \\
              \t\techo "Waiting for $$INSTANCE_ID to register with SSM..."; \\
              \t\tfor i in $$(seq 1 30); do \\
              \t\t\tSTATUS=$$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null); \\
              \t\t\tif [ "$$STATUS" = "Online" ]; then break; fi; \\
              \t\t\tsleep 5; \\
              \t\tdone; \\
              \t\tDB_PASS=$$(aws secretsmanager get-secret-value --secret-id $(DB_SECRET_ARN) --query SecretString --output text | ruby -rjson -e 'print JSON.parse(STDIN.read)["password"]'); \\
              \t\tDB_PASS_URLENC=$$(ruby -rerb -e 'print ERB::Util.url_encode(ARGV[0])' "$$DB_PASS"); \\
              \t\tBOOT_STATUS=1; \\
              \t\tfor attempt in 1 2 3 4 5; do \\
              \t\t\tkill $$TUNNEL_PID 2>/dev/null; \\
              \t\t\techo "Opening an SSM tunnel to $(DB_HOST):5432 and minting era 1 (attempt $$attempt/5)..."; \\
              \t\t\taws ssm start-session --target $$INSTANCE_ID \\
              \t\t\t\t--document-name AWS-StartPortForwardingSessionToRemoteHost \\
              \t\t\t\t--parameters "{\\"host\\":[\\"$(DB_HOST)\\"],\\"portNumber\\":[\\"5432\\"],\\"localPortNumber\\":[\\"15432\\"]}" \\
              \t\t\t\t>/tmp/$(BASTION_STACK)-tunnel-$$attempt.log 2>&1 & \\
              \t\t\tTUNNEL_PID=$$!; \\
              \t\t\tfor i in $$(seq 1 15); do \\
              \t\t\t\tnc -z localhost 15432 2>/dev/null && break; \\
              \t\t\t\tsleep 1; \\
              \t\t\tdone; \\
              \t\t\tcd $(ROOT) && DATABASE_URL="postgres://postgres:$$DB_PASS_URLENC@localhost:15432/#{db_name}" ruby -Ilib -e 'require "hecks"; require "hecks/ports/persistence/plugins/era"; loading = Hecks::Ports::Loading.bootstrap; directory = loading.bluebook_directory(ARGV[0]); root = loading.shared_root(nil, directory); registry = Hecks::Runtime::Registry.new(root: File.dirname(directory)); Hecks.with_registry(registry) { loading.load_library; loading.load_project(root); loading.load_domain(directory) }; bluebook = registry.bluebooks[#{declared_domain_name.inspect}] or abort "no #{declared_domain_name} bluebook loaded"; current_text = Hecks::Runtime::EraCheck.source_text_for(bluebook, directory); Hecks::Adapters::PostgresEra::LineageManager.check!(registry: registry, bluebook: bluebook, current_text: current_text, settings: { database: ENV["DATABASE_URL"]#{hecks_schema ? ", schema: #{hecks_schema.inspect}" : ""} }); db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, { database: ENV["DATABASE_URL"]#{hecks_schema ? ", schema: #{hecks_schema.inspect}" : ""} }); lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name); (registry.bluebooks.values - [bluebook]).each { |other| other.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) } }; db.close; puts "booted OK -- era resolution ran"' $(DOMAIN) && { BOOT_STATUS=0; break; }; \\
              \t\t\tBOOT_STATUS=$$?; \\
              \t\t\techo "boot check attempt $$attempt/5 failed (exit $$BOOT_STATUS) -- restarting the tunnel and retrying in 3s..."; \\
              \t\t\tsleep 3; \\
              \t\tdone; \\
              \t\tkill $$TUNNEL_PID 2>/dev/null; \\
              \t\techo "Tearing down the temporary bastion stack..."; \\
              \t\taws cloudformation delete-stack --stack-name $(BASTION_STACK); \\
              \t\taws cloudformation wait stack-delete-complete --stack-name $(BASTION_STACK); \\
              \t\texit $$BOOT_STATUS
              OWNMINT
            }
          MAKE

          files = { "template.yaml" => template_yaml }
          files["bastion.yaml"] = bastion_yaml if bastion_yaml
          files["Dockerfile"] = dockerfile
          files["Makefile"] = makefile_content
          # Opt-in per-branch previews: nothing is added unless the domain declares a `preview`
          # setting under deployed_to("AwsFargate"). See Preview's own header for the keys.
          preview_main = {
            infra_name: infra_name, stack_name: stack_name, stack_prefix: stack_prefix, region: region,
            cpu: cpu, memory: memory, db_name: shared ? owner_db_name : db_name,
            owner_stack: shared ? owner_stack_name : nil, name: infra_name, port: port,
            image: "#{domain_container.repository_name}:latest", domain: declared_domain_name, web: target.state[:web].value,
            wasm_path: "/usr/local/bin/#{domain_name}.wasm", ir_path: "/usr/local/bin/#{domain_name}.ir.json",
            schema: hecks_schema
          }
          files.merge!(Preview.call(deploy_settings: deploy_settings, main: preview_main))
          Scripts.extend_files(files, deploy_settings: deploy_settings, plan: plan,
                                      stack_name: stack_name, region: region)
        end

        # Renders DB_HOST/DB_NAME/DB_SECRET_ARN — spliced in after `call`'s
        # template heredoc renders; see its `# TMPL:db_env` comment for why.
        def db_env_yaml(shared:, owner_db_name:, db_ref_id:, db_name:, secret_sub:, hecks_schema:, base:, db_name_ref: nil)
          lines =
            if shared
              [
                "- Name: DB_HOST",
                "  Value: !Ref OwningDatabaseEndpoint",
                "- Name: DB_NAME",
                "  Value: #{db_name_ref || owner_db_name}",
                "- Name: DB_SECRET_ARN",
                "  Value: !Sub \"${OwningDatabaseSecretArn}\"",
              ]
            else
              [
                "- Name: DB_HOST",
                "  Value: !GetAtt #{db_ref_id}.Endpoint.Address",
                "- Name: DB_NAME",
                "  Value: #{db_name}",
                "- Name: DB_SECRET_ARN",
                "  Value: !Sub \"${#{secret_sub}}\"",
              ]
            end
          lines += ["- Name: HECKS_SCHEMA", "  Value: #{hecks_schema}"] if hecks_schema

          lines.map { |line| "#{base}#{line}" }.join("\n") + "\n"
        end

        # Renders one `AWS::IAM::Role` `Policies` entry per cross-domain target —
        # the shape that resource type requires, unlike the bare shorthand
        # `Shared.cross_domain_invoke_policy_yaml` renders for SAM.
        def cross_domain_fargate_policy_yaml(targets, base)
          resources = targets.map { |target|
            "#{base}          - !Sub \"arn:aws:lambda:${AWS::Region}:${AWS::AccountId}:function:hecks-#{target.downcase}\""
          }.join("\n")

          [
            "#{base}# Least-privilege, one ARN per declared `across:` target — see",
            "#{base}# Shared.cross_domain_invoke_policy_yaml's own comment for the full",
            "#{base}# reasoning; this domain's own task role needs the identical grant.",
            "#{base}- PolicyName: CrossDomainInvoke",
            "#{base}  PolicyDocument:",
            "#{base}    Version: '2012-10-17'",
            "#{base}    Statement:",
            "#{base}      - Effect: Allow",
            "#{base}        Action: lambda:InvokeFunction",
            "#{base}        Resource:",
            resources,
          ].join("\n") + "\n"
        end
      end
    end
  end
end
