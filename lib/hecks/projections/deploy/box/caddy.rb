module Hecks
  module Projections
    module Deploy
      module Box
        # The proxy's `Caddyfile`: an optional origin-secret guard, one block per route and a
        # default for everything else. Mixed into `Box`, which supplies `template` and the
        # constants.
        module Caddy
          # The proxy's configuration: an optional origin-secret guard, one block per route and a
          # default for everything else.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the Caddyfile
          def caddyfile(plan)
            guarded = !plan.origin_header.nil?
            site =
              if guarded
                "\t@origin header #{plan.origin_header} {$ORIGIN_SECRET}\n\n\thandle @origin {\n" \
                  "#{indent(indent(route_blocks(plan)))}\t}\n\n\thandle {\n\t\trespond \"Forbidden\" 403\n\t}\n"
              else
                indent(route_blocks(plan))
              end
            "#{caddy_header(plan)}#{caddy_global(guarded)}\n:80 {\n#{site}}\n\n#{CADDY_EXTRA}"
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the `handle` blocks for each route, then the default
          def route_blocks(plan)
            routes = plan.routes.each_with_index.map { |route, i| route_block(plan, route, i + 1) }
            "#{routes.join}handle {\n#{upstream(plan.default.port)}}\n"
          end

          # One upstream. A request that arrives while its container is being replaced
          # waits, and is tried again every quarter second for up to 15 seconds, so a
          # deploy shows a visitor a slow page instead of a 502.
          #
          # @param port [Integer] the container's port
          # @return [String] the `reverse_proxy` block, one tab in, ending in a newline
          def upstream(port)
            "\treverse_proxy 127.0.0.1:#{port} {\n\t\tlb_try_duration 15s\n\t\tlb_try_interval 250ms\n\t}\n"
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the comment that opens the Caddyfile
          def caddy_header(plan)
            origin =
              if plan.origin_header
                "Only requests that carry #{plan.origin_header} with the origin secret are proxied;\n" \
                  "# everything else gets a flat 403.\n"
              else
                "Every request is proxied.\n"
              end
            "# #{plan.infra_name}'s proxy. #{origin}"
          end

          # With a guard, the proxy trusts every source: a request that reaches a `handle` block has
          # already proved it came through the CDN by presenting the secret, and everything else is
          # refused. Caddy then keeps the client address the CDN put in X-Forwarded-For.
          #
          # @param guarded [Boolean] whether an origin secret guards the site
          # @return [String] the global options block
          def caddy_global(guarded)
            options = "\t# No certificate for the :80 site. disable_redirects, not off, so a listener a rehearsal\n" \
                      "\t# mounts under caddy-extra can still ask for `tls internal`.\n" \
                      "\tauto_https disable_redirects\n\tadmin off\n"
            return "{\n#{options}}\n" unless guarded

            "{\n#{options}\tservers {\n\t\ttrusted_proxies static 0.0.0.0/0 ::/0\n\t}\n}\n"
          end

          # @param text [String] lines to indent one level with a tab
          # @return [String] the text, each non-blank line prefixed with a tab
          def indent(text)
            text.lines.map { |line| line.strip.empty? ? line : "\t#{line}" }.join
          end

          private

          def route_block(plan, route, number)
            port = plan.containers.find { |c| c.name == route.container }.port
            "@r#{number} path #{route.paths.join(" ")}\nhandle @r#{number} {\n#{upstream(port)}}\n\n"
          end
        end
      end
    end
  end
end
