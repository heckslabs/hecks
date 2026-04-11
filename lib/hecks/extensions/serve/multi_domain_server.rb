require "webrick"
require "json"
require "tmpdir"
Hecks::Chapters.load_aggregates(
  Hecks::Extensions::ServeChapter,
  base_dir: __dir__
)
Hecks::Chapters.load_aggregates(
  Hecks::Extensions::ServeRoutesChapter,
  base_dir: __dir__
)
require "hecks/extensions/web_explorer/renderer"
require "hecks/extensions/web_explorer/ir_introspector"
require "hecks/extensions/web_explorer/runtime_bridge"
require "hecks/extensions/web_explorer/event_introspector"

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
        @entries.each do |entry|
          ir = entry[:ir]
          puts "  #{ir.domain.name}: /#{entry[:slug]}/ (#{ir.aggregate_names.size} aggregates)"
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
        @domains.each_with_index do |domain, domain_index|
          runtime = @runtimes[domain_index]
          slug = domain_slug(domain.name)
          mod = Object.const_get(bluebook_module_name(domain.name))
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
        @entries.each do |entry|
          ir = entry[:ir]
          group = HecksTemplating::UILabelContract.label(ir.domain.name)
          ir.domain.aggregates.each do |agg|
            items << {
              label: HecksTemplating::UILabelContract.plural_label(agg.name),
              href: "/#{entry[:slug]}/#{plural(agg)}",
              group: group
            }
          end
        end
        items << { label: "Events", href: "/events", group: "System" }
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
        elsif path == "/events"
          req["Accept"]&.include?("application/json") ? serve_events_json(res) : serve_events(req, res)
        elsif path == "/config"
          serve_config(res)
        else
          entry = @entries.find { |e_item| path.start_with?("/#{e_item[:slug]}/") || path == "/#{e_item[:slug]}" }
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
      rescue => error
        res.status = 500
        res["Content-Type"] = "text/html"
        res.body = "Error: #{error.message}"
      end

      def serve_home(res)
        agg_data = @entries.flat_map do |entry|
          ir = entry[:ir]
          ir.domain.aggregates.map do |agg|
            home_data = ir.home_aggregate_data(agg, "#{entry[:slug]}/#{plural(agg)}")
            { name: home_data[:name], href: home_data[:href], command_names: home_data[:command_names],
              attributes: home_data[:attributes], policies: home_data[:policies] }
          end
        end
        html = @renderer.render(:home,
          title: @brand, brand: @brand, nav_items: @nav,
          domain_name: @brand, aggregates: agg_data)
        res["Content-Type"] = "text/html"
        res.body = html
      end

      def serve_config(res)
        summaries = @entries.flat_map do |entry|
          ir = entry[:ir]
          ir.domain.aggregates.map do |agg|
            summary = ir.aggregate_summary(agg)
            { name: agg.name, commands: summary[:commands], ports: summary[:ports] }
          end
        end
        policies = @entries.flat_map { |entry| entry[:ir].policy_labels }
        roles = @entries.flat_map { |entry| entry[:ir].available_roles }.uniq
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
        route = entry[:routes].find { |route_def| route_def[:method] == req.request_method && route_matches_request_path?(route_def[:path], sub_path) }
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
        @entries.each do |entry|
          diagram_data = entry[:ir].diagram_data
          combined[:structure_diagram] += diagram_data[:structure_diagram] + "\n"
          combined[:behavior_diagram]  += diagram_data[:behavior_diagram] + "\n"
          combined[:flows_diagram]     += diagram_data[:flows_diagram] + "\n"
        end
        combined.transform_values(&:strip)
      end

      def plural(agg)
        bluebook_aggregate_slug(agg.name)
      end

      def route_matches_request_path?(pattern, path)
        pattern_segments = pattern.split("/")
        actual_segments  = path.split("/")
        return false unless pattern_segments.size == actual_segments.size

        pattern_segments.zip(actual_segments).all? { |pat, act| wildcard?(pat) || pat == act }
      end

      def wildcard?(segment)
        segment.start_with?(":")
      end

    end
  end
end
