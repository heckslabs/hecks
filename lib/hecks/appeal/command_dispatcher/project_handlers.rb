# Hecks::Appeal::CommandDispatcher::ProjectHandlers
#
# Handles project-level commands: discover, open, and close projects.
# Mixed into CommandDispatcher to keep the main class focused on routing.
#
#   # Automatically included by CommandDispatcher
#   include Hecks::Appeal::CommandDispatcher::ProjectHandlers
#
module Hecks
  module Appeal
    class CommandDispatcher
      module ProjectHandlers
        private

        def handle_project_discover_projects(ws, args)
          emit(ws, "ProjectsDiscovered", "Project", { projects: @bridge.discover(args[:path] || Dir.pwd) })
        end

        def handle_project_open_project(ws, args)
          emit(ws, "ProjectOpened", "Project", { project: @bridge.open_project(args[:path]) })
        end

        def handle_project_close_project(ws, args)
          @bridge.projects.delete(args[:path])
          emit(ws, "ProjectClosed", "Project", { path: args[:path] })
        end
      end
    end
  end
end
