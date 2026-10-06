module Hecks
  module Projections
    module Deploy
      module Fargate
        class Stack
          # The ids, names and references of a stack's resources, derived from its plan. Each method
          # is also the value of the template marker of the same name.
          module Readers
            def ids = plan.ids
            def names = plan.names
            def layout = plan.layout
            def domain_container = layout.domain

            def db_id = ids[:database_prefix]
            def db_ref_id = aurora ? "#{db_id}Cluster" : db_id
            def secret_sub = aurora ? "#{db_id}Secret" : "#{db_ref_id}.MasterUserSecret.SecretArn"
            def secret_intrinsic = aurora ? "!Ref #{db_id}Secret" : "!GetAtt #{db_ref_id}.MasterUserSecret.SecretArn"
            def db_secret_ref = shared ? "OwningDatabaseSecretArn" : secret_sub
            def db_name_ref = plan.db_name_parameter ? "!Ref #{plan.db_name_parameter}" : nil

            # Never created when `shared`: this domain's own VPC (and its compute security group) is
            # skipped entirely; the task and ALB-ingress rule reach through the borrowed owner's
            # security group instead.
            def compute_security_group_ref = shared ? "!Ref OwningSecurityGroupId" : "!Ref #{ids[:compute_prefix]}SecurityGroup"

            # `logical_id` stays the derived name in prose (descriptions, comments); the ids below
            # are what the resources are actually declared with, which the world's `logical_ids`
            # setting may replace.
            def service_id = ids[:service]
            def ecr_repository_id = ids[:ecr_repository]
            def cluster_id = ids[:cluster]
            def task_definition_id = ids[:task_definition]
            def execution_role_id = ids[:execution_role]
            def task_role_id = ids[:task_role]
            def log_group_id = ids[:log_group]
            def target_group_id = ids[:target_group]
            def alb_id = ids[:alb]
            def alb_sg_id = ids[:alb_security_group]
            def listener_id = ids[:listener]
            def distribution_id = ids[:distribution]
            def session_secret_id = ids[:session_secret]
            def ingress_from_alb_id = ids[:ingress_from_alb]
            def default_target_group_id = layout.default.target_group_id

            def cluster_name = names[:cluster]
            def log_group_name = names[:log_group]
            def family_name = names[:family]
            def alb_name = names[:alb]
            def service_name = names[:service]
            def db_secret_policy_name = names[:db_secret_policy]

            def alb_sg_description
              names[:alb_security_group_description] ||
                "#{alb_sg_id} - HTTP ingress from CloudFront only, forwarded to #{logical_id} only"
            end

            def repository_name = domain_container.repository_name
            def container_name = domain_container.name
            def tag_parameter = domain_container.tag_parameter
            def health_path = domain_container.health_path

            def port_min = Containers.port_range(layout).min
            def port_max = Containers.port_range(layout).max
            def depends_on = Containers.depends_on(layout, listener_id)
            def vpc_ref = shared ? "!Ref OwningVpcId" : "!Ref #{db_id}Vpc"
            def sidecar_dir = plan.install_dir
            def build_context_dir = plan.build_context_dir
            def cmd_binary = sidecar_dir == Settings::DEFAULT_INSTALL_DIR ? domain_name : "#{sidecar_dir}/#{domain_name}"
            def desired_count_value = plan.desired_count_parameter ? "!Ref #{plan.desired_count_parameter}" : desired_count
            def declared_domain_literal = declared_domain_name.inspect
            def schema_setting = hecks_schema ? ", schema: #{hecks_schema.inspect}" : ""

            def alb_subnets
              return "[!Ref OwningPublicSubnetAId, !Ref OwningPublicSubnetBId]" if shared

              "[!Ref #{db_id}PublicSubnet, !Ref #{db_id}BastionPublicSubnet]"
            end

            def service_subnets
              shared ? "[!Ref OwningSubnetAId, !Ref OwningSubnetBId]" : "[!Ref #{db_id}SubnetA, !Ref #{db_id}SubnetB]"
            end
          end
        end
      end
    end
  end
end
