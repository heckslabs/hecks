require_relative "preview/settings"
require_relative "preview/template"
require_relative "preview/script"

module Hecks
  module Projections
    module Deploy
      # Per-branch preview stacks for a `deployed_to("AwsFargate")` domain: one
      # isolated copy of the stack per git branch, created and torn down by a
      # generated script.
      #
      # Opt-in. A domain with no `preview` setting gets exactly the files it
      # got before; `Fargate.call` asks `requested?` and merges in `call`'s
      # files only when the answer is yes.
      #
      # ## What is generated
      #
      # - `preview.yaml`: a separate CloudFormation template, so a preview never
      #   appears in a change set against the live stack (see `Template`).
      # - `preview.sh`: `deploy` (create or update), `destroy`, `list`, `url`,
      #   `name`, `ensure-database` and `login` (see `Script`).
      # - The database step is a one-shot task declared in `preview.yaml`
      #   and run by `preview.sh`; there is no separate file, because the
      #   instance is reachable only from inside the VPC.
      #
      # ## Settings
      #
      # ```ruby
      # deployed_to("AwsFargate") do
      #   region "us-east-1"
      #   preview do
      #     containers [{ name: "web", port: 8080, host: true, default: true }]
      #   end
      # end
      # ```
      #
      # `preview true` and a block with no settings accept every default. Keys:
      #
      # - `prefix`: stack, cluster, service and image repository name prefix.
      #   Default `<stack_prefix>-<stack>-preview`.
      # - `alb_prefix`: load balancer name prefix, at most 11 characters.
      #   Default the first 8 letters of the stack name plus `pv`.
      # - `owner_stack`: the stack whose VPC, subnets and compute security group
      #   the preview attaches to. Default the `owner_stack` of a Shared main
      #   stack, else the main stack.
      # - `database_stack`: the stack whose outputs name the shared database
      #   instance. Default `owner_stack`.
      # - `database_endpoint_output`, `database_secret_output`: the output keys
      #   holding the instance host and the master secret ARN. Defaults
      #   `DatabaseEndpoint` and `DatabaseSecretArn`.
      # - `db_prefix`: a preview's database is `<db_prefix>_pv_<env>`. Default
      #   the stack name, lowercased, at most 30 characters.
      # - `protected_databases`: names the database task refuses, added to the
      #   main database, `postgres` and the two template databases. Default `[]`.
      # - `protected_branches`: branches `preview.sh` refuses. Default
      #   `["main", "master"]`.
      # - `cpu`, `memory`: task size. Default the main stack's.
      # - `log_retention_days`: a value CloudWatch accepts. Default `7`.
      # - `session_cookie`: cookie name; sets `HECKS_SESSION_COOKIE` on the host
      #   and is what `login` writes. Default the host's own default.
      # - `first_admin`: whether `preview.sh` signs the deployer up and offers
      #   `login`. Default `true`.
      # - `signup_path`: the host route the signup posts to. Default `/signups`.
      # - `landing_path`: the page `login` points the browser at. Default `/`.
      # - `db_init_image`: image of the database task; needs `sh` and `psql`.
      #   Default the public Postgres 16 alpine image.
      # - `containers`: the containers the preview task runs. Default the main
      #   stack's container list; see `Containers` for the entry keys.
      #
      # ## Why a preview mints no era and needs no bastion
      #
      # The host mints era 1 itself on an empty database, and the database
      # task runs inside the VPC, so neither the main stack's bastion nor a
      # tunnel is involved.
      module Preview
        module_function

        # Answers whether a domain opted in to previews.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` settings
        # @return [Boolean] true when a `preview` setting is present and not `false`
        def requested?(deploy_settings)
          value = deploy_settings[:preview]
          !value.nil? && value != false
        end

        # Generates the preview files for one domain.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` settings
        # @param main [Hash{Symbol => Object}] the main stack's facts; see `Settings.build`
        # @return [Hash{String => String}] `"preview.yaml"` and `"preview.sh"`, or `{}` when
        #   the domain did not opt in
        # @raise [ArgumentError] if a preview setting is unknown or malformed
        def call(deploy_settings:, main:)
          return {} unless requested?(deploy_settings)

          settings = Settings.build(deploy_settings[:preview], deploy_settings: deploy_settings, main: main)
          { "preview.yaml" => Template.render(settings), "preview.sh" => Script.render(settings) }
        end
      end
    end
  end
end
