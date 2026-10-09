require_relative "text_template"
require_relative "shared/rows"

module Hecks
  module Projections
    module Deploy
      # VPC, RDS/Aurora, bastion and cross-domain invoke plumbing shared by the
      # `Lambda` and `Fargate` deploy targets. Plain module functions, not a Target.
      module Shared
        # Raised when a bastion parameter names a stack output that is not declared.
        class Error < RuntimeError; end

        # The names a domain's own VPC and database are rendered by.
        #
        # @!attribute [r] shared [Boolean] whether this domain borrows another domain's RDS instance
        # @!attribute [r] db_id [String] shared logical-id prefix of the RDS/VPC resources
        # @!attribute [r] db_ref_id [String] logical id `.Endpoint` resolves against (Cluster for
        # Aurora)
        # @!attribute [r] db_name [String] database identifier RDS/Aurora provisions
        # @!attribute [r] infra_name [String] AWS-facing domain name
        # @!attribute [r] aurora [Boolean] Aurora Serverless v2 when true, plain RDS otherwise
        # @!attribute [r] google_oauth_present [Boolean] whether the NAT/public-subnet resources
        # exist
        Network = Struct.new(:shared, :db_id, :db_ref_id, :db_name, :infra_name, :aurora, :google_oauth_present,
                             keyword_init: true)

        COMMENT_LINES = [
          "least-privilege, one ARN per declared `across:` target -- the same",
          "shape this compute's own DB-secret grant already takes, extended to",
          "a target this stack does not own (so no `!Ref` to reach for -- the",
          "target's own function name is `lambda_client.rs`'s own computed",
          "\"hecks-\#{domain}\" convention, read directly, matching every other"
        ].freeze

        extend Rows

        module_function

        # The stack-to-bastion contract: one table that `template.yaml` Outputs,
        # `bastion.yaml` Parameters and the Makefile overrides all read from.
        # Empty when `shared`, since such a domain provisions no VPC/RDS of its own.
        #
        # @param network [Network] the domain's VPC and database names
        # @param secret_intrinsic [String] rendered `!Ref`/`!GetAtt` for the database secret
        # @param compute_security_group_ref [String] `!Ref` for the compute's security group
        # @return [Array<Hash{Symbol => String}>] frozen `{key:, var:, ref:}` entries
        def stack_outputs(network, secret_intrinsic:, compute_security_group_ref:)
          return [].freeze if network.shared

          outputs = core_outputs(network, secret_intrinsic, compute_security_group_ref)
          outputs += oauth_outputs(network.db_id) if network.google_oauth_present
          outputs.freeze
        end

        # `bastion.yaml`'s Parameters, kept in one table so renames cannot drift
        # from the stack outputs.
        #
        # @param shared [Boolean] see `Network`
        # @param google_oauth_present [Boolean] see `Network`
        # @return [Array<Hash{Symbol => String}>] frozen `{name:, from_output:, type:}` entries
        def bastion_parameters(shared:, google_oauth_present:)
          return [].freeze if shared

          params = [parameter("VpcId", "VpcId", "AWS::EC2::VPC::Id"),
                    parameter("RdsSecurityGroupId", "DbSecurityGroupId", "AWS::EC2::SecurityGroup::Id")]
          params += oauth_parameters if google_oauth_present
          params.freeze
        end

        # Generation-time check that every bastion parameter maps to a stack output.
        #
        # @raise [Error] if a parameter names a `from_output` absent from `stack_outputs`
        def check_bastion_parameters!(bastion_parameters, stack_outputs)
          bastion_parameters.each do |param|
            stack_outputs.any? { |o| o[:key] == param[:from_output] } or
              raise Error, "bastion parameter #{param[:name]} references undeclared stack output #{param[:from_output]}"
          end
        end

        # Renders one `lambda:InvokeFunction` IAM statement per `across:` target,
        # to append to the compute role's `Policies:` list.
        # An ARN for a not-yet-deployed function is valid IAM; the call just fails until then.
        #
        # @param targets [Array<String>] domain names declared by `across:`
        # @param base [String] indentation of the marker line
        # @return [String] the YAML ending in one newline; empty if `targets` is empty
        def cross_domain_invoke_policy_yaml(targets, base)
          return "" if targets.empty?

          resources = targets.map do |target|
            "#{base}        - !Sub \"arn:aws:lambda:${AWS::Region}:${AWS::AccountId}:function:hecks-#{target.downcase}\""
          end
          statement = ["#{base}- Statement:", "#{base}    - Effect: Allow", "#{base}      Action: lambda:InvokeFunction",
                       "#{base}      Resource:", *resources]
          "#{[invoke_comment(targets, base), *statement].join("\n")}\n"
        end

        # Renders a domain's private VPC, subnets, RDS/Aurora Postgres and the two
        # security groups pairing it with its compute, dedented flush-left.
        # The compute group has no inbound rule; it only needs egress to the database.
        #
        # @param network [Network] the domain's VPC and database names
        # @param compute_logical_id [String] logical id naming the compute's security group
        # @param compute_description [String] the compute security group's `GroupDescription`
        # @return [String] the rendered CloudFormation Resources
        def vpc_and_database_yaml(network, compute_logical_id:, compute_description:)
          oauth = network.google_oauth_present
          TextTemplate.render("shared/vpc_and_database.tmpl",
                              db_id: network.db_id, infra_name: network.infra_name, compute_id: compute_logical_id,
                              compute_description: compute_description,
                              nat_gateway: oauth ? render_block("nat_gateway", db_id: network.db_id) : "",
                              oauth_egress: oauth ? render_block("oauth_egress", compute_id: compute_logical_id) : "",
                              database: database_yaml(network)).rstrip
        end

        # Renders the temporary era-minting bastion: a standalone template deployed
        # and destroyed by `make mint-era`. SSM Session Manager only, no inbound rules.
        # Callers skip this when `shared`, as there is no RDS/VPC for it to reach.
        #
        # @param network [Network] the domain's VPC and database names
        # @param domain [String] domain directory path, named in the header comment
        # @param stack_name [String] main stack name, tagged onto the instance
        # @param bastion_parameters [Array<Hash{Symbol => String}>] as `bastion_parameters` builds
        # @return [String] the rendered CloudFormation template
        def bastion_yaml(network, domain:, stack_name:, bastion_parameters:)
          oauth = network.google_oauth_present
          TextTemplate.render("shared/bastion.tmpl", domain: domain, infra_name: network.infra_name,
                                                     parameters: bastion_parameter_lines(bastion_parameters),
                                                     public_subnet: bastion_public_subnet(network),
                                                     subnet_id: oauth ? "BastionSubnetId" : "BastionSubnet",
                                                     stack_name: stack_name)
        end

        def invoke_comment(targets, base)
          lines = [*COMMENT_LINES, "function-name computation in this whole project). Targets: #{targets.join(", ")}."]
          lines.map { |line| "#{base}# #{line}" }.join("\n")
        end
        private_class_method :invoke_comment

        # One of the text blocks spliced into a template, without its trailing blank lines.
        def render_block(name, **values)
          TextTemplate.render("shared/#{name}.tmpl", **values).rstrip
        end
        private_class_method :render_block

        def database_yaml(network)
          kind = network.aurora ? "aurora_db" : "plain_db"
          render_block(kind, db_id: network.db_id, db_name: network.db_name)
        end
        private_class_method :database_yaml

        def bastion_parameter_lines(parameters)
          parameters.map { |p| "#{p[:name]}:\n    Type: #{p[:type]}" }.join("\n  ")
        end
        private_class_method :bastion_parameter_lines

        # The bastion's public subnet block, indented two spaces under `Resources:` after its first
        # line.
        def bastion_public_subnet(network)
          name = network.google_oauth_present ? "bastion_reuse_public" : "bastion_own_public"
          text = TextTemplate.render("shared/#{name}.tmpl", db_id: network.db_id)
          text.each_line.with_index.map { |line, i| (i.zero? ? "" : "  ") + line }.join.rstrip
        end
        private_class_method :bastion_public_subnet
      end
    end
  end
end
