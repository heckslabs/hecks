require_relative "../../projector"
require_relative "shared"
require_relative "text_template"
require_relative "lambda/stack"
require_relative "lambda/pii"

module Hecks
  module Projections
    module Deploy
      # The AWS Lambda deploy target (ADR 0018): renders `template.yaml`,
      # `Makefile`, `samconfig.toml`, and `bastion.yaml` from a domain's `.world`.
      module Lambda
        extend Projector::Target

        projects_as :aws_lambda, needs_world: true, emits: :files

        module_function

        # Renders `template.yaml`, `Makefile`, `samconfig.toml`, and (unless
        # this domain shares another domain's RDS instance) `bastion.yaml`.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's booted chapter
        # @param options [Hash] :world, :domain_dir, :root, :world_file, and
        #   :cross_domain_registry are required; :tenant is optional
        # @return [Hash{String => String}] generated file contents by filename
        # @raise [ArgumentError] if `deployed_to("AwsLambda")` is invalid
        def call(bluebook:, options: {})
          stack = Stack.new(options)
          files = { "template.yaml" => template_yaml(stack) }
          # A separate, sibling stack for the few minutes `make mint-era` needs it, then deleted:
          # SSM Session Manager only, never SSH, no inbound rule at all. Skipped when `shared`:
          # era-minting reuses the owner's own standing infrastructure instead.
          files["bastion.yaml"] = bastion_yaml(stack) unless stack.shared
          files["Makefile"] = TextTemplate.render_from("lambda/Makefile.tmpl", stack)
          # Everything `sam deploy --guided` would ask interactively is already known from the
          # domain's own `deployed_to("AwsLambda")` block.
          files["samconfig.toml"] = TextTemplate.render_from("lambda/samconfig.toml.tmpl", stack)
          files
        end

        # Builds the CloudFront/WAFv2/logging resources a pii-marked domain is fronted by.
        #
        # @param fronted_logical_id [String] the function the distribution fronts
        # @param use_oac [Boolean] whether the distribution signs its requests to the function
        # @param geo_restriction_type [String] `none`, `whitelist` or `blacklist`
        # @param geo_restriction_countries [Array<String>] the country codes the restriction lists
        # @return [String] the resources, indented two spaces under `Resources:`
        def pii_cloudfront_yaml(fronted_logical_id:, use_oac:, geo_restriction_type:, geo_restriction_countries:)
          Pii.cloudfront_yaml(fronted_logical_id: fronted_logical_id, use_oac: use_oac,
                              geo_restriction_type: geo_restriction_type,
                              geo_restriction_countries: geo_restriction_countries)
        end

        # Renders `template.yaml`, then the edits that are made after it renders, not interpolated
        # inside it: a `#{...}` marker at column 0 would drag the template's own dedent computation
        # to zero and leave every other line un-stripped.
        #
        # @param stack [Stack] the stack the world declares
        # @return [String] the SAM template
        def template_yaml(stack)
          text = TextTemplate.render_from("lambda/template.yaml.tmpl", stack)
          text = text.sub(/^([ \t]*)# TMPL:cross_domain_lambda_policies\n/) do
            Shared.cross_domain_invoke_policy_yaml(stack.cross_domain_targets, Regexp.last_match(1))
          end
          text = with_pii_distribution(text, stack) if stack.pii_detected
          stack.dispatch_none ? without_dispatch_function(text, stack) : text
        end

        # Operates on the already-rendered string: the pii resources are built correctly indented,
        # so nothing here interacts with a template's own dedent computation.
        def with_pii_distribution(text, stack)
          resources = pii_cloudfront_yaml(
            fronted_logical_id: stack.web_handler_present ? stack.web_logical_id : stack.logical_id,
            use_oac: !stack.web_handler_present && !stack.rust_web,
            geo_restriction_type: stack.geo_restriction_type, geo_restriction_countries: stack.geo_restriction_countries
          )
          text.sub(/^Outputs:\n/) do
            "#{resources}Outputs:\n  PiiDistributionDomainName:\n    Value: !GetAtt PiiDistribution.DomainName\n"
          end
        end
        private_class_method :with_pii_distribution

        # Surgical removal, post-render, not a nested conditional heredoc: a conditional nested
        # heredoc broke embedded multi-line `#{shared ? ... : ...}` strings inside the resource
        # block, which assume exactly one reindentation layer.
        def without_dispatch_function(text, stack)
          function = Regexp.escape(stack.logical_id)
          # Non-greedy through the resource's own FunctionUrlConfig/AuthType closing pair, so
          # WebFunction's own later "AuthType:" can't match.
          text = text.sub(/^  #{function}:\n.*?\n        AuthType: (?:NONE|AWS_IAM)\n/m, "")
          # Removes the now-dangling `!Ref` to the resource just deleted above: SAM refuses an
          # unresolved Ref at package time, not silently.
          text = text.sub(/^        - LambdaInvokePolicy:\n            FunctionName: !Ref #{function}\n/, "")
          # WebFunction's own URL becomes the stack's only "FunctionUrl".
          text.sub(web_url_output(stack), "  FunctionUrl:\n    Value: !GetAtt #{stack.web_logical_id}Url.FunctionUrl\n")
        end
        private_class_method :without_dispatch_function

        def web_url_output(stack)
          function = Regexp.escape(stack.logical_id)
          web = Regexp.escape(stack.web_logical_id)
          Regexp.new(["^  FunctionUrl:\\n    Value: !GetAtt #{function}Url\\.FunctionUrl\\n",
                      "  WebFunctionUrl:\\n    Value: !GetAtt #{web}Url\\.FunctionUrl\\n"].join)
        end
        private_class_method :web_url_output

        def bastion_yaml(stack)
          Shared.bastion_yaml(stack.network, domain: stack.domain, stack_name: stack.stack_name,
                                             bastion_parameters: stack.bastion_parameters)
        end
        private_class_method :bastion_yaml
      end
    end
  end
end
