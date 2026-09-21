require_relative "../../projector"
require_relative "shared"

module Hecks
  module Projections
    module Deploy
      # The AWS Fargate deploy target. An export
      # (`Projector::Target#projects_as`'s own `needs_world: true`), the
      # same shape `Lambda` is — it reads a domain's own
      # `deployed_to("AwsFargate")` `.world` settings, not only its
      # declaration.
      #
      # `bin/project_deploy` finds and boots the domain's own chapter and
      # its `.world`/`.hecksagon` bindings, calls this through
      # `Projector.call(:aws_fargate, bluebook:, options:, world:)`, and
      # writes the returned tree.
      #
      # ## What this generates
      #
      # A plain CloudFormation stack — an `AWS::ECR::Repository`, an
      # `AWS::ECS::TaskDefinition` (`RequiresCompatibilities: [FARGATE]`,
      # `NetworkMode: awsvpc`) running one container built from the
      # domain's own `rust/host`, an `AWS::ECS::Service` behind an
      # Application Load Balancer fronted by an `AWS::CloudFront::
      # Distribution` (real HTTPS, and a `DefaultCacheBehavior` pinned to
      # Managed-CachingDisabled — see that resource's own comment for
      # why nothing more permissive is a safe default here), and
      # least-privilege task execution/task roles — plus the same private
      # VPC/RDS-or-Aurora instance and temporary era-minting bastion
      # `Lambda` generates, via `Shared`.
      #
      # No SAM: this is deployed with plain `aws cloudformation deploy`,
      # never `sam deploy`, so there is no `samconfig.toml` here. A
      # `Dockerfile` packages `rust/host`'s own compiled binary — built by
      # the generated Makefile before `docker build` ever runs, the same
      # "build outside the container, ship the artifact" shape
      # `lifeadelics/domain/Dockerfile` already uses for a tebako-pressed
      # Ruby binary.
      #
      # ## What this assumes, and does not build
      #
      # `rust/host` runs as a long-lived HTTP server on this domain's own
      # `port` here, not as a Lambda custom-runtime process (`bootstrap`,
      # `Lambda`'s own binary): `HECKS_SERVE_MODE: "1"` (below, in
      # `ContainerDefinitions[0].Environment`) is `rust/host/src/main.rs`'s
      # own top-of-`main` switch into `server.rs`'s axum-based server,
      # which answers this stack's own `GET /` health check with a bare,
      # dispatch-free `200` and routes every other request through the
      # same per-invocation dispatch logic the Lambda target's `bootstrap`
      # binary already runs — see `server.rs`'s own header for the
      # concurrency reasoning (the boot-time Postgres client is already
      # `Arc<Mutex<...>>`-shared, and already anticipated exactly this,
      # per `dispatch.rs`'s own comment on `handle`'s locking).
      #
      # **Still assumed, not built here**: the generated `Dockerfile`'s
      # own `COPY` and the generated Makefile's own `build:` target ship
      # nothing but the compiled `#{domain_name}-host` binary — no
      # `.wasm`/`.ir.json` sidecar, and no `HECKS_WASM_PATH`/
      # `HECKS_IR_PATH` `Environment` entry pointing at one. `main.rs`
      # requires both unconditionally at boot (`ir::ir().ok_or(...)?`,
      # no fallback), so a container built exactly as this module
      # generates it today fails at that line before ever reaching
      # `HECKS_SERVE_MODE`'s own branch — the identical, already-known
      # `HECKS_IR_PATH` gap `checkout.rs`'s own header documents for
      # `Lambda`'s `web "None"` case (confirmed live: `deploy/banking/
      # template.yaml` carries `HECKS_WASM_PATH` but no `HECKS_IR_PATH`
      # either), not a new one this module introduces. Packaging the
      # compiled dispatch artifact alongside the binary is a real,
      # separate task (a Dockerfile/Makefile change, not a `rust/host`
      # one) — flagged plainly here rather than silently discovered and
      # dropped, not fixed in this pass.
      module Fargate
        extend Projector::Target

        projects_as :aws_fargate, needs_world: true, emits: :files

        module_function

        # Generates `template.yaml`, `Makefile`, `Dockerfile`, and (unless
        # this domain borrows another domain's RDS instance)
        # `bastion.yaml` for one domain's `deployed_to("AwsFargate")`
        # deploy target.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter;
        #   establishes admission, see `Lambda.call`'s own comment on why generation
        #   itself reads `options[:cross_domain_registry]` instead
        # @param options [Hash] generation options — see `Lambda.call`'s own `@option`
        #   tags; identical shape, this target reads the same keys
        # @return [Hash{String => String}] `"template.yaml"`, `"Makefile"`, `"Dockerfile"`,
        #   and — unless this domain declares `database "Shared"` — `"bastion.yaml"`
        # @raise [ArgumentError] if the domain's own deploy settings conflict, or
        #   `deploy.bluebook`'s own `FargateTarget.Declare` refuses them
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

          # Same override `Lambda.call` applies, for the same reason — see
          # that method's own comment.
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

          # Every policy in every loaded chapter — see `Lambda.call`'s own
          # comment on why this reads the whole registry, not only this
          # domain's own top-level list.
          cross_domain_fargate_targets = cross_domain_registry.bluebooks.flat_map { |_name, chapter|
            chapter.policies.select(&:target_domain).map(&:target_domain)
          }.uniq.sort

          # **The storehouse** — identical borrowing `Lambda.call` supports for
          # `database "Shared"`; see that method's own comment for the full
          # reasoning. `owner`/`owner_stack` stay Ruby-level `deploy_settings`
          # reads, never validated `FargateTarget` attributes, for the same
          # reason: which domain owns the shared instance is a deploy-time
          # wiring fact, not a business invariant.
          if shared
            owner_domain_name = deploy_settings[:owner] or raise ArgumentError, <<~MSG
              #{world_file}'s deployed_to("AwsFargate") declares database "Shared" but no owner. Add one, e.g.:

                  deployed_to("AwsFargate") do
                    ...
                    database "Shared"
                    owner "Embryonaut"
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

          db_id             = "#{logical_id.sub(/Service\z/, '')}Db"
          db_ref_id         = aurora ? "#{db_id}Cluster" : db_id
          secret_sub        = aurora ? "#{db_id}Secret" : "#{db_ref_id}.MasterUserSecret.SecretArn"
          secret_intrinsic  = aurora ? "!Ref #{db_id}Secret" : "!GetAtt #{db_ref_id}.MasterUserSecret.SecretArn"
          db_secret_ref     = shared ? "OwningDatabaseSecretArn" : secret_sub

          # A Fargate service is reached through an Application Load
          # Balancer sitting in a public subnet, not invoked directly the
          # way a Lambda Function URL is — this domain always needs real
          # internet-facing infrastructure (the `ALB`'s own ingress, and
          # egress for an `ECR` image pull/CloudWatch Logs/Secrets Manager),
          # unlike `Lambda`'s own NAT Gateway, which is opt-in
          # (`google_oauth_present`) because a plain dispatch Lambda needs
          # no internet access at all. `Shared.vpc_and_database_yaml`'s
          # `google_oauth_present:` parameter is exactly this "does this
          # domain need its own NAT Gateway/public subnet" question,
          # unconditionally true here.
          network_needs_internet = true

          # Never created at all when `shared` — the compute-side security
          # group `Shared.vpc_and_database_yaml` would otherwise declare is
          # skipped along with the rest of this domain's own VPC (same as
          # `Lambda.call`'s own Shared-mode `VpcConfig`); the `ECS` task and
          # the `ALB`-ingress rule both reach through the borrowed owner's
          # own security group instead.
          compute_security_group_ref = shared ? "!Ref OwningSecurityGroupId" : "!Ref #{logical_id}SecurityGroup"

          ecr_repository_id = "#{logical_id}Repository"
          cluster_id         = "#{logical_id}Cluster"
          task_definition_id = "#{logical_id}TaskDefinition"
          execution_role_id  = "#{logical_id}ExecutionRole"
          task_role_id       = "#{logical_id}TaskRole"
          log_group_id       = "#{logical_id}LogGroup"
          target_group_id    = "#{logical_id}TargetGroup"
          alb_id             = "#{logical_id}Alb"
          alb_sg_id          = "#{logical_id}AlbSecurityGroup"
          listener_id        = "#{logical_id}Listener"
          distribution_id    = "#{logical_id}Distribution"

          stack_outputs = Shared.stack_outputs(
            shared: shared, db_id: db_id, db_ref_id: db_ref_id, secret_intrinsic: secret_intrinsic,
            compute_security_group_ref: compute_security_group_ref, google_oauth_present: network_needs_internet
          )
          bastion_parameters = Shared.bastion_parameters(shared: shared, google_oauth_present: network_needs_internet)
          Shared.check_bastion_parameters!(bastion_parameters, stack_outputs)

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
            OwningSecurityGroupId:
              Type: AWS::EC2::SecurityGroup::Id
            OwningDatabaseEndpoint:
              Type: String
            OwningDatabaseSecretArn:
              Type: String
          SHAREDPARAMS

          template_yaml = <<~YAML
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh
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
            #{owning_params_yaml.empty? ? "" : "Parameters:\n" + owning_params_yaml.each_line.map { |l| "  #{l}" }.join}
            Resources:
              #{shared ? "" : Shared.vpc_and_database_yaml(
                db_id: db_id, db_name: db_name, infra_name: infra_name, aurora: aurora,
                google_oauth_present: network_needs_internet, compute_logical_id: logical_id,
                compute_description: "#{logical_id} - inbound from #{alb_sg_id} only, egress rules attached separately below"
              ).each_line.with_index.map { |l, i| (i.zero? ? "" : "  ") + l }.join.rstrip}

              #{alb_sg_id}:
                Type: AWS::EC2::SecurityGroup
                Properties:
                  VpcId: #{shared ? "!Ref OwningVpcId" : "!Ref #{db_id}Vpc"}
                  GroupDescription: #{alb_sg_id} - HTTP ingress from CloudFront only, forwarded to #{logical_id} only
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

              #{logical_id}IngressFromAlb:
                Type: AWS::EC2::SecurityGroupIngress
                Properties:
                  GroupId: #{compute_security_group_ref}
                  IpProtocol: tcp
                  FromPort: #{port}
                  ToPort: #{port}
                  SourceSecurityGroupId: !Ref #{alb_sg_id}

              #{ecr_repository_id}:
                Type: AWS::ECR::Repository
                Properties:
                  RepositoryName: #{infra_name}
                  ImageScanningConfiguration:
                    ScanOnPush: true

              #{cluster_id}:
                Type: AWS::ECS::Cluster
                Properties:
                  ClusterName: #{stack_name}

              #{log_group_id}:
                Type: AWS::Logs::LogGroup
                Properties:
                  LogGroupName: /ecs/#{stack_name}
                  RetentionInDays: 30

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
                    - PolicyName: DbSecretRead
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Sub "${#{db_secret_ref}}"

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
                    - PolicyName: DbSecretRead
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Sub "${#{db_secret_ref}}"
                    # TMPL:cross_domain_fargate_policies

              #{task_definition_id}:
                Type: AWS::ECS::TaskDefinition
                Properties:
                  Family: #{infra_name}
                  RequiresCompatibilities: [FARGATE]
                  NetworkMode: awsvpc
                  Cpu: "#{cpu}"
                  Memory: "#{memory}"
                  ExecutionRoleArn: !GetAtt #{execution_role_id}.Arn
                  TaskRoleArn: !GetAtt #{task_role_id}.Arn
                  ContainerDefinitions:
                    - Name: #{infra_name}
                      Image: !Sub "${#{ecr_repository_id}.RepositoryUri}:latest"
                      PortMappings:
                        - ContainerPort: #{port}
                      LogConfiguration:
                        LogDriver: awslogs
                        Options:
                          awslogs-group: !Ref #{log_group_id}
                          awslogs-region: !Ref AWS::Region
                          awslogs-stream-prefix: #{infra_name}
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
                        # TMPL:db_env

              #{target_group_id}:
                Type: AWS::ElasticLoadBalancingV2::TargetGroup
                Properties:
                  TargetType: ip
                  Port: #{port}
                  Protocol: HTTP
                  VpcId: #{shared ? "!Ref OwningVpcId" : "!Ref #{db_id}Vpc"}
                  HealthCheckPath: /
                  HealthCheckPort: "#{port}"

              #{alb_id}:
                Type: AWS::ElasticLoadBalancingV2::LoadBalancer
                Properties:
                  Name: #{stack_name}-alb
                  Scheme: internet-facing
                  Type: application
                  SecurityGroups: [!Ref #{alb_sg_id}]
                  Subnets: #{shared ? "[!Ref OwningSubnetAId, !Ref OwningSubnetBId]" : "[!Ref #{db_id}PublicSubnet, !Ref #{db_id}BastionPublicSubnet]"}

              #{listener_id}:
                Type: AWS::ElasticLoadBalancingV2::Listener
                Properties:
                  LoadBalancerArn: !Ref #{alb_id}
                  Port: 80
                  Protocol: HTTP
                  DefaultActions:
                    - Type: forward
                      TargetGroupArn: !Ref #{target_group_id}

              #{logical_id}:
                Type: AWS::ECS::Service
                DependsOn: #{listener_id}
                Properties:
                  ServiceName: #{stack_name}
                  Cluster: !Ref #{cluster_id}
                  TaskDefinition: !Ref #{task_definition_id}
                  DesiredCount: #{desired_count}
                  LaunchType: FARGATE
                  NetworkConfiguration:
                    AwsvpcConfiguration:
                      AssignPublicIp: DISABLED
                      Subnets: #{shared ? "[!Ref OwningSubnetAId, !Ref OwningSubnetBId]" : "[!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]"}
                      SecurityGroups: [#{compute_security_group_ref}]
                  LoadBalancers:
                    - ContainerName: #{infra_name}
                      ContainerPort: #{port}
                      TargetGroupArn: !Ref #{target_group_id}

              # Real HTTPS (the ALB's own Listener above is HTTP-only —
              # nothing else in this stack terminates TLS) and, just as
              # important, the ONE safe default this generator can offer
              # for caching it has no way to reason about: Managed-
              # CachingDisabled. This domain's own routes — including
              # every hecks-native /login, /logout, /auth/google(/callback),
              # /admin/members request (web.rs's own auth_gate/auth_route,
              # generic across every domain, not just this one's own
              # dispatch commands) — are all session-cookie-driven, and
              # this generator has no way to tell which of a domain's own
              # paths would ever be safe to cache. Found live, the hard
              # way (lifeadelics, 2026-09-21): a hand-authored CloudFront
              # stack applied the OPPOSITE default — a custom, cookie-
              # blind cache policy with a 90-120s TTL — and it served one
              # signed-in session's own response (a short-lived SSO
              # handoff token among them) back to a different, unrelated
              # request within that window. A domain that DOES know one
              # of its own paths is genuinely safe to cache (a public,
              # non-personalized page) adds its own more specific
              # CacheBehavior by hand, the same way lifeadelics's own
              # hand-extended three-container stack already does for
              # /_astro/*, /videos/*, and friends — never by loosening
              # this one.
              #{distribution_id}:
                Type: AWS::CloudFront::Distribution
                Properties:
                  DistributionConfig:
                    Enabled: true
                    HttpVersion: http2
                    # No ACM/custom domain here — this generator has no
                    # notion of one (deploy.bluebook's own FargateTarget
                    # declares no `domain` attribute for it) and CloudFront
                    # requires an ACM cert in us-east-1 specifically to
                    # attach a custom Aliases entry, a real cross-region
                    # dependency this generator can't assume. CloudFront's
                    # own default *.cloudfront.net certificate/hostname
                    # are what Outputs.CloudFrontDomain below reports;
                    # point a real domain's DNS at it by hand, same
                    # "generated, extend by hand" posture this whole file
                    # already has for anything past its own baseline.
                    ViewerCertificate:
                      CloudFrontDefaultCertificate: true
                    Origins:
                      - Id: #{alb_id}Origin
                        DomainName: !GetAtt #{alb_id}.DNSName
                        CustomOriginConfig:
                          OriginProtocolPolicy: http-only
                          HTTPPort: 80
                          HTTPSPort: 443
                    DefaultCacheBehavior:
                      TargetOriginId: #{alb_id}Origin
                      ViewerProtocolPolicy: redirect-to-https
                      Compress: true
                      AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
                      CachedMethods: [GET, HEAD]
                      # Managed-CachingDisabled — see this resource's own
                      # header comment for why nothing else is safe here
                      # by default.
                      CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
                      # Managed-AllViewer — forwards every cookie/header/
                      # query string through uncached, so rust/host's own
                      # session-cookie-based auth sees the real request
                      # exactly as the browser sent it.
                      OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3

            Outputs:
              ServiceUrl:
                Value: !Sub "http://${#{alb_id}.DNSName}"
              CloudFrontDomain:
                Value: !GetAtt #{distribution_id}.DomainName
              #{stack_outputs.map { |o| "#{o[:key]}:\n    Value: #{o[:ref]}" }.join("\n  ")}
          YAML

          # Spliced in after the heredoc renders, not interpolated inside
          # it — `Lambda.call`'s own comment on `# TMPL:cross_domain_lambda_policies`
          # explains why: a `<<~` heredoc's own dedent is computed from its
          # raw source, before any `#{...}` evaluates, so a multi-line
          # value substituted in at runtime is not reindented by the
          # enclosing heredoc a second time — hand-computing a matching
          # prefix in advance drifts out of sync the moment anything
          # upstream shifts this template's own baseline indentation
          # (confirmed the hard way, writing this: the first version
          # hardcoded the raw source column instead of the marker's own
          # actual rendered one, and every subsequent line landed twice as
          # deep as it should have). A plain `String#sub` after the fact,
          # capturing the marker's own real indentation, has no such
          # interaction with the text it replaces into.
          template_yaml = template_yaml.sub(/^([ \t]*)# TMPL:db_env\n/) { db_env_yaml(shared: shared, owner_db_name: owner_db_name, db_ref_id: db_ref_id, db_name: db_name, secret_sub: secret_sub, hecks_schema: hecks_schema, base: $1) }
          template_yaml = template_yaml.sub(/^([ \t]*)# TMPL:cross_domain_fargate_policies\n/) {
            cross_domain_fargate_targets.empty? ? "" : cross_domain_fargate_policy_yaml(cross_domain_fargate_targets, $1)
          }

          bastion_yaml = shared ? nil : Shared.bastion_yaml(
            domain: domain, infra_name: infra_name, stack_name: stack_name, db_id: db_id,
            google_oauth_present: network_needs_internet, bastion_parameters: bastion_parameters
          )

          dockerfile = <<~DOCKERFILE
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh this
            # file rather than hand-editing. Modeled on lifeadelics/domain/Dockerfile's
            # own shape: build the binary outside the image (this directory's own
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

            COPY #{domain_name}-host /usr/local/bin/#{domain_name}-host

            ENV PORT=#{port}
            ENV BIND=0.0.0.0
            EXPOSE #{port}

            CMD ["#{domain_name}-host"]
          DOCKERFILE

          makefile_content = <<~MAKE
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh
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
            \t@rustup target list --installed 2>/dev/null | grep -qx x86_64-unknown-linux-gnu || rustup target add x86_64-unknown-linux-gnu
            \tcd $(ROOT)/rust/host && rustup run stable cargo build --release --target x86_64-unknown-linux-gnu
            \tcp $(ROOT)/rust/host/target/x86_64-unknown-linux-gnu/release/bootstrap #{domain_name}-host

            .PHONY: ecr-login
            ecr-login:
            \taws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$(REGION).amazonaws.com

            .PHONY: docker-build
            docker-build: build
            \tdocker build --platform linux/amd64 -t #{infra_name}:$(IMAGE_TAG) .

            .PHONY: docker-push
            docker-push: ecr-login
            \tACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \\
            \t\tdocker tag #{infra_name}:$(IMAGE_TAG) $$ACCOUNT_ID.dkr.ecr.$(REGION).amazonaws.com/#{infra_name}:$(IMAGE_TAG); \\
            \t\tdocker push $$ACCOUNT_ID.dkr.ecr.$(REGION).amazonaws.com/#{infra_name}:$(IMAGE_TAG)

            .PHONY: deploy
            deploy: docker-build docker-push
            #{shared ? "\t@echo \"Looking up #{owner_stack_name}'s shared VpcId/PrivateSubnetAId/PrivateSubnetBId/FunctionSecurityGroupId/DatabaseEndpoint/DatabaseSecretArn outputs to pass as $(STACK)'s Owning* parameters...\"\n\tOWNER_VPC_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue\" --output text); \\\n\t\tOWNER_SUBNET_A_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='PrivateSubnetAId'].OutputValue\" --output text); \\\n\t\tOWNER_SUBNET_B_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='PrivateSubnetBId'].OutputValue\" --output text); \\\n\t\tOWNER_SG_ID=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='FunctionSecurityGroupId'].OutputValue\" --output text); \\\n\t\tOWNER_DB_HOST=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='DatabaseEndpoint'].OutputValue\" --output text); \\\n\t\tOWNER_DB_SECRET_ARN=$$(aws cloudformation describe-stacks --stack-name #{owner_stack_name} --query \"Stacks[0].Outputs[?OutputKey=='DatabaseSecretArn'].OutputValue\" --output text); \\\n\t\taws cloudformation deploy --template-file template.yaml --stack-name $(STACK) --region $(REGION) --capabilities CAPABILITY_IAM \\\n\t\t\t--parameter-overrides OwningVpcId=$$OWNER_VPC_ID OwningSubnetAId=$$OWNER_SUBNET_A_ID OwningSubnetBId=$$OWNER_SUBNET_B_ID OwningSecurityGroupId=$$OWNER_SG_ID OwningDatabaseEndpoint=$$OWNER_DB_HOST OwningDatabaseSecretArn=$$OWNER_DB_SECRET_ARN" : "\taws cloudformation deploy --template-file template.yaml --stack-name $(STACK) --region $(REGION) --capabilities CAPABILITY_IAM"}
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
          files
        end

        # Renders the container's own `DB_HOST`/`DB_NAME`/`DB_SECRET_ARN`
        # (and, when set, `HECKS_SCHEMA`) `Environment` entries — the
        # borrowed-owner values for a Shared-mode domain, this domain's
        # own RDS/Aurora endpoint otherwise. See `call`'s own comment on
        # `# TMPL:db_env` for why this is spliced in after the enclosing
        # template renders, not interpolated inline.
        #
        # @param shared [Boolean] whether this domain borrows another domain's
        #   RDS instance
        # @param owner_db_name [String, nil] the owning domain's own database name,
        #   used only when `shared`
        # @param db_ref_id [String] the logical id `.Endpoint` resolves against
        # @param db_name [String] this domain's own database identifier
        # @param secret_sub [String] the `${...}`-ready identifier for this domain's
        #   own database secret
        # @param hecks_schema [String, nil] the Postgres schema to set, or nil for none
        # @param base [String] the marker line's own rendered indentation whitespace
        # @return [String] the rendered `ContainerDefinitions[0].Environment` entries,
        #   ending in exactly one trailing newline
        def db_env_yaml(shared:, owner_db_name:, db_ref_id:, db_name:, secret_sub:, hecks_schema:, base:)
          lines =
            if shared
              [
                "- Name: DB_HOST",
                "  Value: !Ref OwningDatabaseEndpoint",
                "- Name: DB_NAME",
                "  Value: #{owner_db_name}",
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

        # Renders the cross-domain policy's own least-privilege invoke
        # grant as a plain `AWS::IAM::Role` `Policies` list entry — the
        # `PolicyName`/`PolicyDocument` shape that resource type requires,
        # unlike the bare `{Statement: [...]}` shorthand
        # `Shared.cross_domain_invoke_policy_yaml` renders for SAM's own
        # `AWS::Serverless::Function.Policies` property. Not called at all
        # when `targets` is empty — see `call`'s own `# TMPL:cross_domain_fargate_policies`
        # splice.
        #
        # @param targets [Array<String>] the domain names this stack's `across:` targets
        #   declare
        # @param base [String] the marker line's own rendered indentation whitespace
        # @return [String] one `Policies` list entry, ending in exactly one trailing newline
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
