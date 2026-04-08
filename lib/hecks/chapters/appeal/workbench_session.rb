# Hecks::Chapters::Appeal::WorkbenchSessionParagraph
#
# Domain paragraph for the workbench chapter of HecksAppeal.
# Defines aggregates for IDE session lifecycle, panel layout,
# and menu bar interactions.
#
#   Hecks::Chapters::Appeal::WorkbenchSessionParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module WorkbenchSessionParagraph
        def self.define(b)
          b.aggregate "Workbench" do
            description "Live domain interaction. Select a project, execute commands, inspect state."
            attribute :active_project, String
            attribute :active_aggregate, String

            command "ShowWorkbench" do
              description "Open the workbench REPL for this domain"
              emits "WorkbenchShown"
            end

            command "SelectProject" do
              description "Set the active project for command dispatch"
              attribute :project_name, String
              emits "ProjectSelected"
            end

            command "SelectAggregate" do
              description "Set the active aggregate for inspection"
              attribute :aggregate_name, String
              emits "AggregateSelected"
            end

            command "ExecuteCommand" do
              description "Dispatch a command against the active project's runtime"
              attribute :command_name, String
              attribute :args, String
              emits "CommandExecuted"
            end

            command "InspectRepository" do
              description "List all records in an aggregate's repository"
              attribute :aggregate_name, String
              emits "RepositoryInspected"
            end

            command "FindRecord" do
              description "Find a single record by ID"
              attribute :aggregate_name, String
              attribute :record_id, String
              emits "RecordFound"
            end

            command "ShowEventHistory" do
              description "Show all events for the active project"
              emits "EventHistoryShown"
            end
          end

          b.aggregate "Session" do
            description "IDE session with sketch/play modes and WebSocket connection state."
            attribute :mode, String, default: "sketch"
            attribute :connection_status, String, default: "disconnected"

            command "EnterSketch" do
              description "Switch to sketch mode for editing domain structure"
              reference_to "Session"
              emits "SketchEntered"
            end

            command "EnterPlay" do
              description "Switch to play mode for executing domain commands"
              reference_to "Session"
              emits "PlayEntered"
            end

            command "Connect" do
              description "Establish WebSocket connection to the IDE server"
              reference_to "Session"
              emits "Connected"
            end

            command "Disconnect" do
              description "Close the WebSocket connection"
              reference_to "Session"
              emits "Disconnected"
            end

            command "RestoreConnection" do
              description "Drop and re-establish the WebSocket connection"
              reference_to "Session"
              emits "ConnectionRestored"
            end
          end

          b.aggregate "Layout" do
            description "IDE panel and tab state. Tracks which panels are open, active tabs, sizes, and arrangement."
            attribute :panels, list_of("PanelState")
            attribute :active_tab, String
            attribute :sidebar_collapsed, String, default: "false"
            attribute :events_panel_collapsed, String, default: "false"

            value_object "PanelState" do
              description "State of a single IDE panel -- name, visibility, dimensions"
              attribute :name, String
              attribute :open, String, default: "true"
              attribute :width, Integer
              attribute :height, Integer
              attribute :position, String
            end

            reference_to "Session"

            command "OpenPanel" do
              description "Show a hidden panel"
              reference_to "Layout"
              attribute :panel_name, String
              emits "PanelOpened"
            end

            command "ClosePanel" do
              description "Hide a panel"
              reference_to "Layout"
              attribute :panel_name, String
              emits "PanelClosed"
            end

            command "SelectTab" do
              description "Switch the active tab in the main area"
              reference_to "Layout"
              attribute :tab_name, String
              emits "TabSelected"
            end

            command "ResizePanel" do
              description "Change a panel's dimensions"
              reference_to "Layout"
              attribute :panel_name, String
              attribute :width, Integer
              attribute :height, Integer
              emits "PanelResized"
            end

            command "ToggleSidebar" do
              description "Collapse or expand the sidebar"
              reference_to "Layout"
              emits "SidebarToggled"
            end

            command "ToggleEventsPanel" do
              description "Collapse or expand the bottom events panel"
              reference_to "Layout"
              emits "EventsPanelToggled"
            end

            command "HideProjects" do
              description "Hide the projects sidebar panel"
              reference_to "Layout"
              emits "ProjectsHidden"
            end

            command "ShowProjects" do
              description "Show the projects sidebar panel"
              reference_to "Layout"
              emits "ProjectsShown"
            end

            command "TrackCurrentFile" do
              description "Record the currently open file and domain for context"
              reference_to "Layout"
              attribute :path, String
              attribute :domain, String
              emits "CurrentFileTracked"
            end

            command "SaveState" do
              description "Persist the current layout state to disk"
              reference_to "Layout"
              emits "StateSaved"
            end

            command "RestoreState" do
              description "Load persisted layout state from disk"
              reference_to "Layout"
              emits "StateRestored"
            end
          end

          b.aggregate "Menu" do
            description "IDE menu bar with File, View, and Domain menus."
            attribute :open_menu, String
            attribute :items, list_of("MenuItem")

            value_object "MenuItem" do
              description "A single menu entry -- label, action, keyboard shortcut, enabled state"
              attribute :label, String
              attribute :action, String
              attribute :shortcut, String
              attribute :enabled, String, default: "true"
              attribute :separator, String, default: "false"
            end

            command "OpenMenu" do
              description "Open a menu dropdown -- File, View, or Domain"
              attribute :menu_name, String
              emits "MenuOpened"
            end

            command "CloseMenu" do
              description "Close any open menu dropdown"
              reference_to "Menu"
              emits "MenuClosed"
            end

            command "SelectMenuItem" do
              description "Execute a menu item action"
              reference_to "Menu"
              attribute :menu_name, String
              attribute :action, String
              emits "MenuItemSelected"
            end
          end

          b.aggregate "KeyboardShortcut" do
            description "Keyboard shortcut binding. Maps key combinations to domain commands."
            attribute :key, String
            attribute :modifiers, String
            attribute :command_aggregate, String
            attribute :command_name, String

            command "BindShortcut" do
              description "Register a keyboard shortcut for a command"
              attribute :key, String
              attribute :modifiers, String
              attribute :command_aggregate, String
              attribute :command_name, String
              emits "ShortcutBound"
            end

            command "TriggerShortcut" do
              description "Fire the command associated with a key combination"
              attribute :key, String
              attribute :modifiers, String
              emits "ShortcutTriggered"
            end
          end
        end
      end
    end
  end
end
