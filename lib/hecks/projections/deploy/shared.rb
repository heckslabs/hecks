module Hecks
  module Projections
    module Deploy
      # Plumbing `Lambda` and `Fargate` both need — VPC/subnet/security-group
      # resources, RDS/Aurora, `bastion.yaml`, and a cross-domain policy's
      # own least-privilege invoke grant are the same problem (get a
      # domain's own Postgres instance stood up and reachable for the one
      # boot that mints era 1, and let a domain call another domain's
      # Lambda) whichever compute target ships the domain's own code.
      #
      # Plain module functions, not a registered `Projector::Target` — this
      # has no `deployed_to(...)` block of its own to generate from, only
      # helpers the two real targets call with the facts they have already
      # resolved (`db_id`, `aurora`, `google_oauth_present`, and so on).
      #
      # Every `*_table` method here answers the same `key`/`var`/`name`
      # strings regardless of which target built them — `stack_outputs`'
      # own `"FunctionSecurityGroupId"` key, in particular, is what a
      # Shared-mode domain looks up from its owner's stack (`bin/project_deploy`'s
      # own Shared-mode branch), and that lookup has to succeed the same
      # way whether the owner is a `Lambda` or a `Fargate` deploy.
      module Shared
        module_function

        # The stack↔bastion contract — one shared table each of
        # `template.yaml`'s Outputs, `bastion.yaml`'s Parameters, and a
        # Makefile's own eval/`--parameter-overrides` lines reads from,
        # instead of three to four independent string literals per fact
        # with nothing checking they agree. `var` is the Make variable
        # each output becomes.
        #
        # Empty when `shared` — a Shared-mode domain provisions no
        # VPC/RDS of its own to expose at all (`bastion_parameters`,
        # `bastion_yaml`, and era-minting are all skipped for the same
        # reason: there's nothing here for a bastion to reach). A
        # Shared-mode domain's own stack is never an owner, so nothing
        # downstream ever needs to look these up from it either.
        #
        # @param shared [Boolean] whether this domain borrows another domain's
        #   RDS instance (`database "Shared"`) rather than provisioning its own
        # @param db_id [String] the RDS/VPC resources' own shared logical-id prefix
        # @param db_ref_id [String] the logical id `.Endpoint`/`.MasterUserSecret` resolve
        #   against — `db_id` itself for plain RDS, `"#{db_id}Cluster"` for Aurora
        # @param secret_intrinsic [String] the rendered `!Ref`/`!GetAtt` expression for
        #   this domain's own database secret
        # @param compute_security_group_ref [String] the `!Ref` expression for the
        #   compute resource's own security group (a Lambda function's, an `ECS`
        #   service's) — reused by a Shared-mode domain elsewhere to attach its own
        #   compute to this domain's VPC without minting a security group of its own
        # @param google_oauth_present [Boolean] whether this domain's own NAT
        #   Gateway/public-subnet resources exist, and so whether `PublicSubnetId`/
        #   `BastionSubnetId` are real outputs to expose
        # @return [Array<Hash{Symbol => String}>] frozen; each entry a `{key:, var:,
        #   ref:}` triple
        def stack_outputs(shared:, db_id:, db_ref_id:, secret_intrinsic:, compute_security_group_ref:, google_oauth_present:)
          return [].freeze if shared

          [
            { key: "VpcId",             var: "VPC_ID",        ref: "!Ref #{db_id}Vpc" },
            { key: "DbSecurityGroupId", var: "DB_SG_ID",       ref: "!Ref #{db_id}SecurityGroup" },
            { key: "DatabaseEndpoint",  var: "DB_HOST",       ref: "!GetAtt #{db_ref_id}.Endpoint.Address" },
            { key: "DatabaseSecretArn", var: "DB_SECRET_ARN", ref: secret_intrinsic },
            # Not consumed by anything in this domain's own generated output —
            # a "Shared"-mode domain elsewhere looks these two up live to
            # attach its own compute to this domain's VPC/security group
            # without minting either itself.
            { key: "FunctionSecurityGroupId", var: "FN_SG_ID",            ref: compute_security_group_ref },
            { key: "PrivateSubnetAId",        var: "PRIVATE_SUBNET_A_ID", ref: "!Ref #{db_id}SubnetA" },
            { key: "PrivateSubnetBId",        var: "PRIVATE_SUBNET_B_ID", ref: "!Ref #{db_id}SubnetB" },
            # Only when google_oauth_present — #{db_id}PublicSubnet (and the
            # Internet Gateway it's attached through) only exist as resources
            # at all when the NAT Gateway block does. `bastion.yaml` needs
            # this: a VPC accepts only one attached Internet Gateway, and one
            # already exists once this is true — its own temporary IGW+subnet
            # would collide (a real, live "Resource.AlreadyAssociated").
            *(google_oauth_present ? [{ key: "PublicSubnetId", var: "PUBLIC_SUBNET_ID", ref: "!Ref #{db_id}PublicSubnet" }] : []),
            # A separate subnet from PublicSubnetId, same shared route
            # table/Internet Gateway -- #{db_id}PublicSubnet always lands in
            # AZ index 0 (`!Select [0, !GetAZs '']`), and a real, live
            # CREATE_FAILED caught this account unable to launch any EC2
            # instance there at all ("Your requested instance type ... is
            # not supported in your requested Availability Zone
            # (us-east-1a)") -- NatGateway and RDS aren't EC2 instances and
            # never hit this, only BastionInstance does. AZ index 1 instead,
            # matching #{db_id}SubnetB's own choice.
            *(google_oauth_present ? [{ key: "BastionSubnetId", var: "BASTION_SUBNET_ID", ref: "!Ref #{db_id}BastionPublicSubnet" }] : []),
          ].freeze
        end

        # `bastion.yaml`'s own Parameters — deliberately allowed to rename
        # (`RdsSecurityGroupId` reads better inside `bastion.yaml` than the
        # stack output's own `DbSecurityGroupId`), which is exactly the kind
        # of rename that can silently drift between the two files without
        # this shared table.
        #
        # @param shared [Boolean] whether this domain borrows another domain's
        #   RDS instance — see `stack_outputs`' own comment
        # @param google_oauth_present [Boolean] see `stack_outputs`
        # @return [Array<Hash{Symbol => String}>] frozen; each entry a `{name:,
        #   from_output:, type:}` triple
        def bastion_parameters(shared:, google_oauth_present:)
          return [].freeze if shared

          [
            { name: "VpcId",              from_output: "VpcId",             type: "AWS::EC2::VPC::Id" },
            { name: "RdsSecurityGroupId", from_output: "DbSecurityGroupId", type: "AWS::EC2::SecurityGroup::Id" },
            *(google_oauth_present ? [{ name: "PublicSubnetId", from_output: "PublicSubnetId", type: "AWS::EC2::Subnet::Id" }] : []),
            *(google_oauth_present ? [{ name: "BastionSubnetId", from_output: "BastionSubnetId", type: "AWS::EC2::Subnet::Id" }] : []),
          ].freeze
        end

        # A generation-time assertion, not a bluebook refusal — this is the
        # generator catching its own bug immediately, before writing a
        # single file, instead of producing a `bastion.yaml` whose Parameter
        # nothing could ever fill.
        #
        # @param bastion_parameters [Array<Hash{Symbol => String}>] as `bastion_parameters` builds
        # @param stack_outputs [Array<Hash{Symbol => String}>] as `stack_outputs` builds
        # @return [void]
        # @raise [RuntimeError] if any parameter names a `from_output` absent from
        #   `stack_outputs`
        def check_bastion_parameters!(bastion_parameters, stack_outputs)
          bastion_parameters.each do |param|
            stack_outputs.any? { |o| o[:key] == param[:from_output] } or
              raise "bastion parameter #{param[:name]} references undeclared stack output #{param[:from_output]}"
          end
        end

        # Renders the least-privilege IAM grant a cross-domain policy's own
        # invoke needs — one `lambda:InvokeFunction` statement per declared
        # `across:` target, appended to the compute role's existing
        # `Policies:` list. `rust/host`'s own `lambda_client.rs`
        # (`AwsLambdaInvoker`) is the one piece of a cross-domain dispatch
        # path that needs this at all, regardless of which compute target
        # ships the calling domain's own code — a Fargate task and a Lambda
        # function both reach another domain's dispatch Lambda the same way.
        #
        # Declared, not deployed: an ARN naming a function that does not
        # exist yet is still valid IAM policy — the call simply fails with
        # `ResourceNotFoundException` instead of `AccessDeniedException`
        # until the target domain is deployed for real.
        #
        # @param targets [Array<String>] the domain names this stack's `across:` targets
        #   declare
        # @param base [String] the marker line's own rendered indentation whitespace;
        #   everything below is built relative to it
        # @return [String] the rendered comment plus one `Statement`-shaped IAM policy
        #   entry granting invoke on each target's function ARN, ending in exactly one
        #   trailing newline; an empty string if `targets` is empty
        def cross_domain_invoke_policy_yaml(targets, base)
          return "" if targets.empty?

          comment = [
            "least-privilege, one ARN per declared `across:` target -- the same",
            "shape this compute's own DB-secret grant already takes, extended to",
            "a target this stack does not own (so no `!Ref` to reach for -- the",
            "target's own function name is `lambda_client.rs`'s own computed",
            '"hecks-#{domain}" convention, read directly, matching every other',
            "function-name computation in this whole project). Targets: #{targets.join(', ')}.",
          ].map { |line| "#{base}# #{line}" }.join("\n")

          resources = targets.map { |target|
            "#{base}        - !Sub \"arn:aws:lambda:${AWS::Region}:${AWS::AccountId}:function:hecks-#{target.downcase}\""
          }.join("\n")

          [
            comment,
            "#{base}- Statement:",
            "#{base}    - Effect: Allow",
            "#{base}      Action: lambda:InvokeFunction",
            "#{base}      Resource:",
            resources,
          ].join("\n") + "\n"
        end

        # Renders one domain's own private VPC, subnets, RDS/Aurora Postgres
        # instance, and the two security groups pairing it with its compute
        # — everything `Lambda` and `Fargate` both need to give a
        # non-`"Shared"`-mode domain a real, reachable Postgres endpoint.
        # Dedented flush-left, the same shape a caller's own enclosing
        # `<<~` heredoc expects to reindent as it splices this in.
        #
        # `compute_logical_id`'s own security group carries no inbound rule
        # at all — neither a Lambda function nor a Fargate task/`ALB` target
        # group receives traffic over this VPC-attached `ENI` directly, only
        # egress to the database (and, when `google_oauth_present`, to the
        # internet for a real OAuth token exchange).
        #
        # @param db_id [String] the RDS/VPC resources' own shared logical-id prefix
        # @param db_name [String] the database identifier RDS/Aurora provisions
        # @param infra_name [String] the domain's own AWS-facing name, quoted in the
        #   `DBSubnetGroupDescription`
        # @param aurora [Boolean] Aurora Serverless v2 when true, plain RDS otherwise
        # @param google_oauth_present [Boolean] whether a NAT Gateway, public subnet, and
        #   the compute security group's own internet egress rule are needed
        # @param compute_logical_id [String] the compute resource's own logical id,
        #   naming its security group and egress rules
        # @param compute_description [String] the compute security group's own
        #   `GroupDescription` text — what actually terminates the `ENI` this ingress
        #   pairs with
        # @return [String] the rendered CloudFormation Resources, flush-left
        def vpc_and_database_yaml(db_id:, db_name:, infra_name:, aurora:, google_oauth_present:, compute_logical_id:, compute_description:)
          <<~OWNDB.rstrip
            #{db_id}Vpc:
              Type: AWS::EC2::VPC
              Properties:
                CidrBlock: 10.0.0.0/16
                EnableDnsSupport: true
                EnableDnsHostnames: true

            #{db_id}SubnetA:
              Type: AWS::EC2::Subnet
              Properties:
                VpcId: !Ref #{db_id}Vpc
                CidrBlock: 10.0.1.0/24
                AvailabilityZone: !Select [0, !GetAZs '']

            #{db_id}SubnetB:
              Type: AWS::EC2::Subnet
              Properties:
                VpcId: !Ref #{db_id}Vpc
                CidrBlock: 10.0.2.0/24
                AvailabilityZone: !Select [1, !GetAZs '']

            #{google_oauth_present ? <<~NATGW.rstrip : ""}
              # Real Google OAuth token exchange needs real internet access --
              # see the enclosing template's own "NO NAT GATEWAY" comment for
              # why this is opt-in. One NAT Gateway, one public subnet, wired
              # only when google_oauth_present -- nothing else in this stack
              # pays for it.
              #{db_id}PublicSubnet:
                Type: AWS::EC2::Subnet
                Properties:
                  VpcId: !Ref #{db_id}Vpc
                  CidrBlock: 10.0.3.0/24
                  AvailabilityZone: !Select [0, !GetAZs '']
                  MapPublicIpOnLaunch: true

              #{db_id}InternetGateway:
                Type: AWS::EC2::InternetGateway

              #{db_id}InternetGatewayAttachment:
                Type: AWS::EC2::VPCGatewayAttachment
                Properties:
                  VpcId: !Ref #{db_id}Vpc
                  InternetGatewayId: !Ref #{db_id}InternetGateway

              #{db_id}PublicRouteTable:
                Type: AWS::EC2::RouteTable
                Properties:
                  VpcId: !Ref #{db_id}Vpc

              #{db_id}PublicRoute:
                Type: AWS::EC2::Route
                DependsOn: #{db_id}InternetGatewayAttachment
                Properties:
                  RouteTableId: !Ref #{db_id}PublicRouteTable
                  DestinationCidrBlock: 0.0.0.0/0
                  GatewayId: !Ref #{db_id}InternetGateway

              #{db_id}PublicSubnetRouteTableAssociation:
                Type: AWS::EC2::SubnetRouteTableAssociation
                Properties:
                  SubnetId: !Ref #{db_id}PublicSubnet
                  RouteTableId: !Ref #{db_id}PublicRouteTable

              # A second public subnet, AZ index 1 -- not where NatGateway
              # lives (that's still #{db_id}PublicSubnet, AZ index 0). Only
              # for bastion.yaml's own BastionInstance, a real EC2 instance
              # that a real, live CREATE_FAILED proved this account can't
              # launch in AZ index 0 at all. Same shared
              # #{db_id}PublicRouteTable/#{db_id}InternetGateway as
              # #{db_id}PublicSubnet, not a second IGW -- a VPC accepts only one.
              #{db_id}BastionPublicSubnet:
                Type: AWS::EC2::Subnet
                Properties:
                  VpcId: !Ref #{db_id}Vpc
                  CidrBlock: 10.0.4.0/24
                  AvailabilityZone: !Select [1, !GetAZs '']
                  MapPublicIpOnLaunch: true

              #{db_id}BastionPublicSubnetRouteTableAssociation:
                Type: AWS::EC2::SubnetRouteTableAssociation
                Properties:
                  SubnetId: !Ref #{db_id}BastionPublicSubnet
                  RouteTableId: !Ref #{db_id}PublicRouteTable

              #{db_id}NatEip:
                Type: AWS::EC2::EIP
                Properties:
                  Domain: vpc

              #{db_id}NatGateway:
                Type: AWS::EC2::NatGateway
                Properties:
                  SubnetId: !Ref #{db_id}PublicSubnet
                  AllocationId: !GetAtt #{db_id}NatEip.AllocationId

              # #{db_id}SubnetA/B (private -- the compute and RDS live here)
              # have no route to the internet at all without this: routes
              # outbound through #{db_id}NatGateway instead of an Internet
              # Gateway directly -- the whole reason a NAT (not just an IGW)
              # exists: outbound-only, no inbound path back into these subnets.
              #{db_id}PrivateRouteTable:
                Type: AWS::EC2::RouteTable
                Properties:
                  VpcId: !Ref #{db_id}Vpc

              #{db_id}PrivateRoute:
                Type: AWS::EC2::Route
                Properties:
                  RouteTableId: !Ref #{db_id}PrivateRouteTable
                  DestinationCidrBlock: 0.0.0.0/0
                  NatGatewayId: !Ref #{db_id}NatGateway

              #{db_id}SubnetARouteTableAssociation:
                Type: AWS::EC2::SubnetRouteTableAssociation
                Properties:
                  SubnetId: !Ref #{db_id}SubnetA
                  RouteTableId: !Ref #{db_id}PrivateRouteTable

              #{db_id}SubnetBRouteTableAssociation:
                Type: AWS::EC2::SubnetRouteTableAssociation
                Properties:
                  SubnetId: !Ref #{db_id}SubnetB
                  RouteTableId: !Ref #{db_id}PrivateRouteTable

            NATGW
            #{db_id}SubnetGroup:
              Type: AWS::RDS::DBSubnetGroup
              Properties:
                DBSubnetGroupDescription: !Sub "${AWS::StackName} - private subnets for #{infra_name}'s own RDS instance"
                SubnetIds: [!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]

            # No inline SecurityGroupEgress/Ingress on either group -- each
            # would need to reference the other's id from inside its own
            # Properties, a genuine circular create-order dependency
            # CloudFormation refuses outright (cfn-lint E3004). Standard
            # fix: create both groups empty, then wire the cross-reference
            # through two standalone rule resources below, each of which
            # can legitimately depend on both groups already existing.
            #{compute_logical_id}SecurityGroup:
              Type: AWS::EC2::SecurityGroup
              Properties:
                VpcId: !Ref #{db_id}Vpc
                GroupDescription: #{compute_description}

            #{db_id}SecurityGroup:
              Type: AWS::EC2::SecurityGroup
              Properties:
                VpcId: !Ref #{db_id}Vpc
                GroupDescription: #{db_id} - ingress rule attached separately below, from #{compute_logical_id} only

            #{compute_logical_id}EgressToDb:
              Type: AWS::EC2::SecurityGroupEgress
              Properties:
                GroupId: !Ref #{compute_logical_id}SecurityGroup
                IpProtocol: tcp
                FromPort: 5432
                ToPort: 5432
                DestinationSecurityGroupId: !Ref #{db_id}SecurityGroup

            #{google_oauth_present ? <<~OAUTHEGRESS.rstrip : ""}
              # A standalone AWS::EC2::SecurityGroupEgress resource for a
              # group replaces that group's own default allow-all-outbound
              # rule with only what's explicitly declared here --
              # #{compute_logical_id}EgressToDb's own existence already means
              # #{compute_logical_id}SecurityGroup has no other egress at
              # all. 443 to 0.0.0.0/0, not a narrower destination -- Google
              # publishes no fixed IP range for oauth2.googleapis.com an AWS
              # security group could reference instead.
              #{compute_logical_id}EgressToInternet:
                Type: AWS::EC2::SecurityGroupEgress
                Properties:
                  GroupId: !Ref #{compute_logical_id}SecurityGroup
                  IpProtocol: tcp
                  FromPort: 443
                  ToPort: 443
                  CidrIp: 0.0.0.0/0

            OAUTHEGRESS
            #{db_id}IngressFromFunction:
              Type: AWS::EC2::SecurityGroupIngress
              Properties:
                GroupId: !Ref #{db_id}SecurityGroup
                IpProtocol: tcp
                FromPort: 5432
                ToPort: 5432
                SourceSecurityGroupId: !Ref #{compute_logical_id}SecurityGroup

            #{if aurora
                <<~AURORADB.rstrip
                  # Aurora Serverless v2, Postgres-compatible -- the split
                  # shape Aurora needs (a DBCluster carrying the managed
                  # password/endpoint/subnet-group/security-group, plus at
                  # least one DBInstance inside it) is the only thing
                  # different from the plain-RDS path below;
                  # Adapters::PostgresEra/tokio_postgres speak the identical
                  # wire protocol against either endpoint.
                  # Self-managed, not ManageMasterUserPassword: true --
                  # CloudFormation's `{{resolve:secretsmanager:...}}` only
                  # resolves an auto-rotating managed secret fresh at the
                  # compute resource's own creation, and RDS's managed-
                  # password feature rotates the password itself shortly
                  # after standing up the cluster -- every subsequent
                  # invocation would keep authenticating with the now-stale
                  # original value. A self-managed secret (generated once,
                  # here, never auto-rotated) has nothing to go stale.
                  #{db_id}Secret:
                    Type: AWS::SecretsManager::Secret
                    Properties:
                      GenerateSecretString:
                        SecretStringTemplate: '{"username":"postgres"}'
                        GenerateStringKey: password
                        PasswordLength: 32
                        ExcludeCharacters: '"@/'

                  #{db_id}Cluster:
                    Type: AWS::RDS::DBCluster
                    DeletionPolicy: Snapshot
                    UpdateReplacePolicy: Snapshot
                    DependsOn: #{db_id}Secret
                    Properties:
                      Engine: aurora-postgresql
                      EngineVersion: "16.14"
                      DatabaseName: #{db_name}
                      MasterUsername: postgres
                      MasterUserPassword: !Sub "{{resolve:secretsmanager:${#{db_id}Secret}:SecretString:password}}"
                      StorageEncrypted: true
                      DBSubnetGroupName: !Ref #{db_id}SubnetGroup
                      VpcSecurityGroupIds: [!Ref #{db_id}SecurityGroup]
                      ServerlessV2ScalingConfiguration:
                        MinCapacity: 0.5
                        MaxCapacity: 1

                  #{db_id}Instance:
                    Type: AWS::RDS::DBInstance
                    DeletionPolicy: Snapshot
                    UpdateReplacePolicy: Snapshot
                    Properties:
                      Engine: aurora-postgresql
                      DBInstanceClass: db.serverless
                      DBClusterIdentifier: !Ref #{db_id}Cluster
                      PubliclyAccessible: false
                AURORADB
              else
                <<~PLAINDB.rstrip
                  #{db_id}:
                    Type: AWS::RDS::DBInstance
                    DeletionPolicy: Snapshot
                    UpdateReplacePolicy: Snapshot
                    Properties:
                      Engine: postgres
                      EngineVersion: "16.14"
                      DBInstanceClass: db.t4g.micro
                      AllocatedStorage: "20"
                      StorageEncrypted: true
                      DBName: #{db_name}
                      MasterUsername: postgres
                      ManageMasterUserPassword: true
                      PubliclyAccessible: false
                      DBSubnetGroupName: !Ref #{db_id}SubnetGroup
                      VPCSecurityGroups: [!Ref #{db_id}SecurityGroup]
                PLAINDB
              end}
          OWNDB
        end

        # Renders the temporary era-minting bastion — a standalone
        # CloudFormation template, deployed and destroyed by `make
        # mint-era`, never merged into the main stack. SSM Session Manager
        # only, never SSH: no key pair, no inbound security group rule at
        # all — the only way in is `aws ssm start-session`, itself gated by
        # the caller's own IAM permissions.
        #
        # Callers skip this entirely when `shared` — a Shared-mode domain
        # provisions no RDS/VPC of its own for a bastion to reach, and era-
        # minting for it reuses its owner's own already-standing bastion
        # path instead.
        #
        # @param domain [String] the domain directory's path, named in the header comment
        # @param infra_name [String] the domain's own AWS-facing name
        # @param stack_name [String] the main stack's own name, tagged onto the bastion instance
        # @param db_id [String] the RDS/VPC resources' own shared logical-id prefix, as
        #   `vpc_and_database_yaml` names them
        # @param google_oauth_present [Boolean] whether the main stack already has its own
        #   public subnet/Internet Gateway to reuse, rather than minting a second one
        # @param bastion_parameters [Array<Hash{Symbol => String}>] as `bastion_parameters` builds
        # @return [String] the rendered CloudFormation template
        def bastion_yaml(domain:, infra_name:, stack_name:, db_id:, google_oauth_present:, bastion_parameters:)
          <<~YAML
            # GENERATED by bin/project_deploy #{domain} — re-run it to refresh
            # this file rather than hand-editing. Deployed and destroyed by
            # `make mint-era` (this directory's own Makefile) — never left
            # running: it exists only long enough for one Ruby boot to reach
            # #{infra_name}'s private RDS instance and mint era 1.
            AWSTemplateFormatVersion: '2010-09-09'
            Description: >
              TEMPORARY — #{infra_name}'s era-minting bastion. Deployed and torn
              down by `make mint-era`; not meant to run continuously.

            # bastion_parameters (Shared.bastion_parameters) — the other end of
            # the contract the main template's own Outputs comment describes;
            # the Makefile's --parameter-overrides line fills these from the
            # same table.
            Parameters:
              #{bastion_parameters.map { |p| "#{p[:name]}:\n    Type: #{p[:type]}" }.join("\n  ")}

            Resources:
              #{google_oauth_present ? <<~REUSEPUBLIC.each_line.with_index.map { |l, i| (i.zero? ? "" : "  ") + l }.join.rstrip : <<~OWNPUBLIC.each_line.with_index.map { |l, i| (i.zero? ? "" : "  ") + l }.join.rstrip}
                # BastionSubnetId, not a subnet minted here — the main
                # template's own #{db_id}BastionPublicSubnet (and the
                # Internet Gateway it shares with #{db_id}PublicSubnet)
                # already exist once google_oauth_present is true, and a VPC
                # accepts only one attached Internet Gateway: this stack's
                # own BastionInternetGateway (below, the no-oauth branch)
                # would collide with it. Its own subnet, not PublicSubnetId
                # directly, despite sharing that subnet's route table --
                # PublicSubnetId's AZ can't launch EC2 instances at all on
                # this account.
              REUSEPUBLIC
                # A new public subnet, not the RDS's own private ones --
                # those have no internet route at all, and the SSM agent
                # needs to reach AWS's own SSM endpoints over HTTPS.
                # 10.0.99.0/24 is picked to sit outside the main template's
                # own 10.0.1.0/24 and 10.0.2.0/24 ranges inside the same /16 VPC.
                BastionSubnet:
                  Type: AWS::EC2::Subnet
                  Properties:
                    VpcId: !Ref VpcId
                    CidrBlock: 10.0.99.0/24
                    AvailabilityZone: !Select [1, !GetAZs '']
                    MapPublicIpOnLaunch: true

                BastionInternetGateway:
                  Type: AWS::EC2::InternetGateway

                BastionVpcGatewayAttachment:
                  Type: AWS::EC2::VPCGatewayAttachment
                  Properties:
                    VpcId: !Ref VpcId
                    InternetGatewayId: !Ref BastionInternetGateway

                BastionRouteTable:
                  Type: AWS::EC2::RouteTable
                  Properties:
                    VpcId: !Ref VpcId

                BastionInternetRoute:
                  Type: AWS::EC2::Route
                  DependsOn: BastionVpcGatewayAttachment
                  Properties:
                    RouteTableId: !Ref BastionRouteTable
                    DestinationCidrBlock: 0.0.0.0/0
                    GatewayId: !Ref BastionInternetGateway

                BastionSubnetRouteTableAssociation:
                  Type: AWS::EC2::SubnetRouteTableAssociation
                  Properties:
                    SubnetId: !Ref BastionSubnet
                    RouteTableId: !Ref BastionRouteTable

              OWNPUBLIC
              # Zero Ingress rules — SSM Session Manager is outbound-only from
              # the instance's side (it dials out to AWS's SSM service), so
              # nothing needs to reach this instance over the network at all,
              # despite it sitting in a public subnet with a public IP.
              BastionSecurityGroup:
                Type: AWS::EC2::SecurityGroup
                Properties:
                  VpcId: !Ref VpcId
                  # A plain hyphen, not an em-dash - EC2's GroupDescription
                  # field rejects any non-ASCII character outright.
                  GroupDescription: "TEMPORARY era-minting bastion - SSM only, no inbound rules"

              BastionToRds:
                Type: AWS::EC2::SecurityGroupIngress
                Properties:
                  GroupId: !Ref RdsSecurityGroupId
                  IpProtocol: tcp
                  FromPort: 5432
                  ToPort: 5432
                  SourceSecurityGroupId: !Ref BastionSecurityGroup

              BastionRole:
                Type: AWS::IAM::Role
                Properties:
                  AssumeRolePolicyDocument:
                    Version: '2012-10-17'
                    Statement:
                      - Effect: Allow
                        Principal: { Service: ec2.amazonaws.com }
                        Action: sts:AssumeRole
                  ManagedPolicyArns:
                    - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

              BastionInstanceProfile:
                Type: AWS::IAM::InstanceProfile
                Properties:
                  Roles: [!Ref BastionRole]

              BastionInstance:
                Type: AWS::EC2::Instance
                Properties:
                  # Amazon Linux 2023's own SSM parameter — always the current
                  # AL2023 AMI for whatever region this deploys into, never a
                  # hand-copied, region-specific, staleness-prone AMI id.
                  ImageId: "{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}"
                  InstanceType: t3.micro
                  SubnetId: !Ref #{google_oauth_present ? "BastionSubnetId" : "BastionSubnet"}
                  SecurityGroupIds: [!Ref BastionSecurityGroup]
                  IamInstanceProfile: !Ref BastionInstanceProfile
                  Tags:
                    - { Key: Name, Value: #{stack_name}-bastion }

            Outputs:
              InstanceId:
                Value: !Ref BastionInstance
          YAML
        end
      end
    end
  end
end
