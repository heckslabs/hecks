# Hecks::Appeal::IdeServer
#
# @domain Session.Connect, Project.OpenProject, Project.DiscoverProjects, Layout
#
# Boots the HecksAppeal IDE by starting capabilities from the runtime.
# Everything is capability-driven — no hand-rolled infrastructure.
#
#   server = IdeServer.new(bridge, runtimes)
#   server.run
#
require "json"

module Hecks
  module Appeal
    class IdeServer
      def initialize(bridge, runtimes)
        @bridge = bridge
        @runtimes = runtimes
      end

      # Start all capabilities and block on the static assets server.
      def run
        runtime = @runtimes.first
        return puts("[Appeal] No runtime — cannot start IDE") unless runtime

        print_projects if @bridge
        start_websocket(runtime)
        start_live_reload(runtime)
        start_static_assets(runtime)
      end

      private

      def print_projects
        return unless @bridge
      end

      def start_websocket(runtime)
        return unless runtime.respond_to?(:websocket)
        port = runtime.websocket
        port.on_connect { |client| push_state(port, client) }
        register_project_runtimes(port)
        runtime.websocket_adapter.start_async
        puts "WebSocket on ws://localhost:#{runtime.websocket_adapter.instance_variable_get(:@listen_port) rescue "?"}"
      end

      def register_project_runtimes(port)
        return unless @bridge
        runtime = @runtimes.first
        @bridge.projects.each do |_path, project|
          (project[:runtimes] || []).each do |rt|
            port.add_runtime(project[:name], rt)
            # Also register with workbench handler if available
            runtime.workbench.add_runtime(project[:name], rt) if runtime&.respond_to?(:workbench)
            puts "    \e[36m▶\e[0m #{rt.domain.name} (#{rt.domain.aggregates.size} aggregates)"
          end
        end
      end

      def start_live_reload(runtime)
        return unless runtime.respond_to?(:live_reload)
        runtime.live_reload.start_async
        puts "Live reload watching for .bluebook changes"
      end

      def start_static_assets(runtime)
        if runtime.respond_to?(:static_assets_adapter)
          url = "http://localhost:#{runtime.static_assets.listen_port}"
          puts "\e]8;;#{url}\e\\#{url}\e]8;;\e\\"
          puts ""
          runtime.static_assets_adapter.start
        else
          puts "[Appeal] No :static_assets capability — cannot serve UI"
        end
      end

      def push_state(port, client)
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world&.to_h : nil
        state = @bridge ? @bridge.to_state.merge(cwd: Dir.pwd, world: world) : { cwd: Dir.pwd, world: world }

        # Restore persisted layout from runtime repo
        runtime = @runtimes.first
        if runtime
          layout = load_persisted_layout(runtime)
          state[:layout] = layout if layout
        end

        port.send_json(client, { type: "state", data: state })
      end

      def load_persisted_layout(runtime)
        repo = runtime["Layout"] rescue nil
        return nil unless repo
        records = repo.respond_to?(:all) ? repo.all : []
        return nil if records.empty?
        record = records.last
        {
          active_tab: record.respond_to?(:active_tab) ? record.active_tab : nil,
          sidebar_collapsed: record.respond_to?(:sidebar_collapsed) ? record.sidebar_collapsed == "true" : false,
          events_panel_collapsed: record.respond_to?(:events_panel_collapsed) ? record.events_panel_collapsed == "true" : false
        }.compact
      rescue
        nil
      end
    end
  end
end
