require "webrick"
require "json"
require "tmpdir"
require_relative "route_builder"
require_relative "cors_headers"
require_relative "csrf_helpers"
require "hecks/extensions/web_explorer/renderer"
require "hecks/extensions/web_explorer/ir_introspector"
require "hecks/extensions/web_explorer/runtime_bridge"
require_relative "multi_domain_ui_routes"

module Hecks
  module HTTP
    # Hecks::HTTP::MultiDomainServer
    #
    # WEBrick server that serves multiple Hecks domains in one process.
    # All structural discovery (aggregates, attributes, commands, policies)
    # comes from the Bluebook IR via IRIntrospector. Runtime access for
    # CRUD operations is isolated behind RuntimeBridge.
    #
    #   domains = [blog_domain, photos_domain]
    #   runtimes = [blog_runtime, photos_runtime]
    #   MultiDomainServer.new(domains, runtimes, port: 9292).run
    #
    class MultiDomainServer
      include HecksTemplating::NamingHelpers
      include UIRoutes
      include Hecks::HTTP::CorsHeaders
      include CsrfHelpers

      def initialize(domains, runtimes, port: 9292)
        @domains = domains
        @runtimes = runtimes
        @port = port
        @entries = []
        setup_domains
      end

      def run
        puts "Hecks serving #{@domains.size} domains on http://localhost:#{@port}"
        @entries.each do |e|
          ir = e[:ir]
          puts "  #{ir.domain.name}: /#{e[:slug]}/ (#{ir.aggregate_names.size} aggregates)"
        end
        puts ""

        server = WEBrick::HTTPServer.new(
          Port: @port, Logger: WEBrick::Log.new("/dev/null"), AccessLog: []
        )
        server.mount_proc("/") { |req, res| handle(req, res) }
        trap("INT") { server.shutdown }
        server.start
      end

      private

      def setup_domains
        @domains.each_with_index do |domain, i|
          runtime = @runtimes[i]
          slug = domain_slug(domain.name)
          mod = Object.const_get(domain_module_name(domain.name))
          ir = Hecks::WebExplorer::IRIntrospector.new(domain)
          whitelist = Hecks::Conventions::DispatchContract.build_whitelist(domain)
          bridge = Hecks::WebExplorer::RuntimeBridge.new(mod, whitelist: whitelist)
          routes = RouteBuilder.new(domain, mod).build
          @entries << { ir: ir, bridge: bridge, runtime: runtime, slug: slug, routes: routes }
        end

        require "hecks/extensions/web_explorer"
        explorer_file = $LOADED_FEATURES.find { |f| f.include?("web_explorer.rb") && f.include?("extensions") }
        views_dir = File.join(File.dirname(explorer_file), "web_explorer/views")
        @renderer = Hecks::WebExplorer::Renderer.new(views_dir)
        @nav = build_nav
        @brand = @domains.map(&:name).join(" + ")
      end

      def build_nav
        items = [{ label: "Home", href: "/" }]
        @entries.each do |e|
          ir = e[:ir]
          group = HecksTemplating::UILabelContract.label(ir.domain.name)
          ir.domain.aggregates.each do |agg|
            items << {
              label: HecksTemplating::UILabelContract.plural_label(agg.name),
              href: "/#{e[:slug]}/#{plural(agg)}",
              group: group
            }
          end
        end
        items << { label: "Config", href: "/config", group: "System" }
        items
      end

      def handle(req, res)
        apply_cors_origin(res)
        res["Access-Control-Allow-Methods"] = "GET, POST, PATCH, DELETE, OPTIONS"
        res["Access-Control-Allow-Headers"] = "Content-Type, X-CSRF-Token, Authorization"
        return if req.request_method == "OPTIONS"

        path = req.path
        if path == "/"
          serve_home(res)
        elsif path == "/config"
          serve_config(res)
        else
          entry = @entries.find { |e| path.start_with?("/#{e[:slug]}/") || path == "/#{e[:slug]}" }
          if entry
            sub_path = path.sub("/#{entry[:slug]}", "")
            sub_path = "/" if sub_path.empty?
            serve_domain_route(req, res, entry, sub_path)
          else
            res.status = 404
            res["Content-Type"] = "text/html"
            res.body = "Not found"
          end
        end
      rescue => e
        res.status = 500
        res["Content-Type"] = "text/html"
        res.body = "Error: #{e.message}"
      end

      def serve_home(res)
        agg_data = @entries.flat_map do |e|
          ir = e[:ir]
          ir.domain.aggregates.map do |agg|
            d = ir.home_aggregate_data(agg, "#{e[:slug]}/#{plural(agg)}")
            { name: d[:name], href: d[:href], command_names: d[:command_names],
              attributes: d[:attributes], policies: d[:policies] }
          end
        end
        html = @renderer.render(:home,
          title: @brand, brand: @brand, nav_items: @nav,
          domain_name: @brand, aggregates: agg_data)
        res["Content-Type"] = "text/html"
        res.body = html
      end

      def serve_config(res)
        summaries = @entries.flat_map do |e|
          ir = e[:ir]
          ir.domain.aggregates.map do |agg|
            s = ir.aggregate_summary(agg)
            { name: agg.name, commands: s[:commands], ports: s[:ports] }
          end
        end
        policies = @entries.flat_map { |e| e[:ir].policy_labels }
        roles = @entries.flat_map { |e| e[:ir].available_roles }.uniq
        diagrams = merge_diagrams
        html = @renderer.render(:config,
          title: "Config — #{@brand}", brand: @brand, nav_items: @nav,
          aggregates: summaries, policies: policies, roles: roles,
          current_role: "admin", adapter: "memory", events: [],
          **diagrams)
        res["Content-Type"] = "text/html"
        res.body = html
      end

      def serve_domain_route(req, res, entry, sub_path)
        route = entry[:routes].find { |r| r[:method] == req.request_method && match?(r[:path], sub_path) }
        if route && req["Accept"]&.include?("application/json")
          if csrf_required?(req) && !valid_csrf_json?(req)
            res.status = 403
            res["Content-Type"] = "application/json"
            res.body = JSON.generate(error: "CSRF token mismatch")
            return
          end
          wrapper = DomainServer::RequestWrapper.new(req)
          result = route[:handler].call(wrapper)
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(result)
          return
        end
        serve_ui_route(req, res, entry, sub_path)
      end

      def merge_diagrams
        combined = { structure_diagram: "", behavior_diagram: "", flows_diagram: "" }
        @entries.each do |e|
          d = e[:ir].diagram_data
          combined[:structure_diagram] += d[:structure_diagram] + "\n"
          combined[:behavior_diagram]  += d[:behavior_diagram] + "\n"
          combined[:flows_diagram]     += d[:flows_diagram] + "\n"
        end
        combined.transform_values(&:strip)
      end

      def plural(agg)
        domain_aggregate_slug(agg.name)
      end

      def match?(pattern, path)
        pp = pattern.split("/"); ap = path.split("/")
        pp.size == ap.size && pp.zip(ap).all? { |p, a| p.start_with?(":") || p == a }
      end
    end
  end
end
