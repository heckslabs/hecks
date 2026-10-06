require "json"

module Hecks
  module Projections
    module Deploy
      module Box
        # What the box's Compose file is rendered from: the script that renders it and the
        # `services.json` it reads. Mixed into `Box`, which supplies `template`.
        module Compose
          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated region
          # @return [String] the script that renders the Compose file, from `services.json` or from
          #   an ECS task definition when the world names one
          def render_compose_sh(plan, region)
            if plan.task_definition
              template("render-compose-taskdef.sh.tmpl", "STACK" => plan.infra_name, "FAMILY" => plan.task_definition,
                                                          "PROXY_IMAGE" => plan.proxy_image)
            else
              template("render-compose.sh.tmpl", "STACK" => plan.infra_name, "REGION" => region,
                                                 "DB_NAME" => plan.database_name, "PROXY_IMAGE" => plan.proxy_image)
            end
          end

          # The compose source: one entry per container, plus the origin secret the proxy checks.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] `services.json`
          def services_json(plan)
            services = plan.containers.to_h { |c| [c.name, service_entry(plan, c)] }
            document = { "services" => services, "origin" => origin_entry(plan) }
            document["task_definition"] = plan.task_definition if plan.task_definition
            document["tunnel"] = tunnel_entry(plan.tunnel_service) if plan.tunnel_service
            # An empty object prints as `{}` or `{` newline `}`, depending on the json gem.
            "#{JSON.pretty_generate(document).gsub(/\{\s*\}/, "{}")}\n"
          end

          # A container's entry. With a task definition the image, environment and secrets are read
          # from it at deploy time, so only the name and port are written here.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @param container [Settings::Container] the container
          # @return [Hash{String => Object}] its entry in `services.json`
          def service_entry(plan, container)
            entry = { "name" => container.name, "port" => container.port }
            return entry if plan.task_definition

            { "name" => container.name, "repository" => container.repository, "port" => container.port,
              "env" => container.env, "secrets" => container.secrets }
          end

          # @param tunnel [Settings::Tunnel] the declared tunnel service
          # @return [Hash{String => Object}] its entry in `services.json`
          def tunnel_entry(tunnel)
            { "url" => "http://127.0.0.1:#{tunnel.port}", "token_secret" => tunnel.token_secret, "image" => tunnel.image }
          end

          private

          def origin_entry(plan)
            return nil unless plan.origin_secret

            origin = { "header" => plan.origin_header, "secret" => plan.origin_secret }
            origin["env"] = plan.origin_env if plan.origin_env.any?
            origin
          end
        end
      end
    end
  end
end
