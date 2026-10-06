module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # The web app's own Lambda: opt-in by a `lambda_handler.rb` beside the world, with its
          # secrets, OAuth wiring and Function URL. Included into `Stack`; each method is also the
          # value of the template marker of the same name.
          module Web
            # Every line of the function indented two spaces under `Resources:`.
            def web_function
              return "" unless web_handler_present

              TextTemplate.render_from("lambda/web_function.tmpl", self).each_line.map { |line| "  #{line}" }.join
            end

            def web_schema_env
              hecks_schema ? "\n        HECKS_SCHEMA: #{hecks_schema}" : ""
            end

            def web_webhook_env
              return "" unless webhook_secret_env

              "\n        #{webhook_secret_env}_ARN: !Sub \"${#{web_logical_id}WebhookSecret}\""
            end

            def web_webhook_policy
              return "" unless webhook_secret_env

              ["", "      - Statement:", "          - Effect: Allow", "            Action: secretsmanager:GetSecretValue",
               "            Resource: !Sub \"${#{web_logical_id}WebhookSecret}\""].join("\n")
            end

            def webhook_secret_resource
              return "" unless webhook_secret_env

              TextTemplate.render_from("lambda/webhook_secret_resource.tmpl", self).rstrip
            end

            def web_oauth_policy
              return "" unless google_oauth_present

              tail_indent(TextTemplate.render_from("lambda/web_oauth_policy.tmpl", self), "      ")
            end

            # Built outside the template so re-indenting it cannot shift this YAML out of sync with
            # the Environment it joins.
            def web_google_oauth_env_yaml
              file = google_oauth_present ? "lambda/web_google_oauth_env.tmpl" : "lambda/web_no_oauth_env.tmpl"
              tail_indent(TextTemplate.render_from(file, self), "        ")
            end
          end
        end
      end
    end
  end
end
