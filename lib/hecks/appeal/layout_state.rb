# Hecks::Appeal::LayoutState
#
# Per-client UI layout state for the IDE. Tracks sidebar visibility,
# events panel, active tab, open panels, and project list visibility.
# Persists to .hecks_appeal_state.json so state survives restarts.
#
#   state = LayoutState.restore(Dir.pwd)
#   state.toggle_sidebar
#   state.save(Dir.pwd)
#
require "json"

module Hecks
  module Appeal
    class LayoutState
      STATE_FILE = ".hecks_appeal_state.json"

      attr_accessor :agent_mode

      DEFAULTS = {
        sidebar_collapsed: false,
        events_collapsed: false,
        active_tab: "agent",
        projects_hidden: false,
        open_panels: [],
        stream_paused: false,
        event_filter: nil,
        diagram_view: "structure",
        current_file_path: nil,
        current_domain: nil
      }.freeze

      def initialize
        @data = DEFAULTS.dup
        @data[:open_panels] = []
        @agent_mode = "memory"
      end

      # Restore layout state from disk, falling back to defaults.
      #
      # @param dir [String] directory containing the state file
      # @return [LayoutState]
      def self.restore(dir)
        state = new
        path = File.join(dir, STATE_FILE)
        return state unless File.exist?(path)

        saved = JSON.parse(File.read(path), symbolize_names: true)
        DEFAULTS.each_key do |k|
          state.instance_variable_get(:@data)[k] = saved[k] unless saved[k].nil?
        end
        state.agent_mode = saved[:agent_mode] if saved[:agent_mode]
        state
      rescue
        new
      end

      # Persist current layout state to disk.
      #
      # @param dir [String] directory to write the state file
      def save(dir)
        path = File.join(dir, STATE_FILE)
        File.write(path, JSON.pretty_generate(to_h))
      rescue => e
        $stderr.puts "[LayoutState] Save failed: #{e.message}"
      end

      def to_h
        @data.merge(agent_mode: @agent_mode)
      end

      def toggle_sidebar
        @data[:sidebar_collapsed] = !@data[:sidebar_collapsed]
      end

      def toggle_events_panel
        @data[:events_collapsed] = !@data[:events_collapsed]
      end

      def hide_projects
        @data[:projects_hidden] = true
      end

      def show_projects
        @data[:projects_hidden] = false
      end

      def select_tab(tab)
        @data[:active_tab] = tab
      end

      def open_panel(panel)
        @data[:open_panels] << panel unless @data[:open_panels].include?(panel)
      end

      def close_panel(panel)
        @data[:open_panels].delete(panel)
      end

      def pause_stream
        @data[:stream_paused] = true
      end

      def resume_stream
        @data[:stream_paused] = false
      end

      def clear_events
        # Client-side; server just acknowledges
      end

      def filter_events(filter)
        @data[:event_filter] = filter
      end

      def select_diagram_view(view)
        @data[:diagram_view] = view
      end

      def track_file(path, domain)
        @data[:current_file_path] = path
        @data[:current_domain] = domain
      end
    end
  end
end
