# Hecks::Appeal::CommandDispatcher::LayoutHandlers
#
# Handles layout, menu, screenshot, search, and debug commands.
# Mixed into CommandDispatcher for UI state management.
#
#   # Automatically included by CommandDispatcher
#   include Hecks::Appeal::CommandDispatcher::LayoutHandlers
#
module Hecks
  module Appeal
    class CommandDispatcher
      module LayoutHandlers
        private

        # -- Layout --
        def layout_cmd(ws, method, event)
          layout(ws).send(method)
          emit(ws, event, "Layout", layout(ws).to_h)
        end

        def layout_cmd_with_arg(ws, method, event, arg)
          layout(ws).send(method, arg)
          emit(ws, event, "Layout", layout(ws).to_h)
        end

        def handle_layout_toggle_sidebar(ws, _) = layout_cmd(ws, :toggle_sidebar, "SidebarToggled")
        def handle_layout_toggle_events_panel(ws, _) = layout_cmd(ws, :toggle_events_panel, "EventsPanelToggled")
        def handle_layout_hide_projects(ws, _) = layout_cmd(ws, :hide_projects, "ProjectsHidden")
        def handle_layout_show_projects(ws, _) = layout_cmd(ws, :show_projects, "ProjectsShown")
        def handle_layout_select_tab(ws, args) = layout_cmd_with_arg(ws, :select_tab, "TabSelected", args[:tab])
        def handle_layout_open_panel(ws, args) = layout_cmd_with_arg(ws, :open_panel, "PanelOpened", args[:panel])
        def handle_layout_close_panel(ws, args) = layout_cmd_with_arg(ws, :close_panel, "PanelClosed", args[:panel])

        def handle_layout_track_current_file(ws, args)
          layout(ws).track_file(args[:path], args[:domain])
        end

        def handle_layout_save_state(ws, _)
          layout(ws).save(Dir.pwd)
          emit(ws, "StateSaved", "Layout", layout(ws).to_h)
        end

        def handle_layout_restore_state(ws, _)
          restored = LayoutState.restore(Dir.pwd)
          @client_state[ws.object_id] = restored
          emit(ws, "StateRestored", "Layout", restored.to_h)
        end

        # -- Menu --
        def handle_menu_open_menu(ws, args) = emit(ws, "MenuOpened", "Menu", { menu: args[:menu] })
        def handle_menu_close_menu(ws, _) = emit(ws, "MenuClosed", "Menu", {})
        def handle_menu_select_menu_item(ws, args) = emit(ws, "MenuItemSelected", "Menu", { item: args[:item] })

        # -- Search --
        def handle_search_search_domain(ws, args)
          emit(ws, "SearchCompleted", "Search", { query: args[:query], results: @bridge.search(args[:query]) })
        end

        def handle_search_clear_search(ws, _) = emit(ws, "SearchCleared", "Search", {})

        # -- Debug --
        def handle_debug_console_error(ws, args)
          warn "[Browser] #{args[:message]}"
        end

        # -- Screenshot --
        def handle_screenshot_capture_screen(ws, args)
          if args[:frame_data]
            path = @screenshots.save(args[:frame_data], args[:timestamp])
            emit(ws, "ScreenshotCaptured", "Screenshot", { frame: File.basename(path) })
          end
        end

        def handle_screenshot_pause_capture(ws, _) = emit(ws, "CapturePaused", "Screenshot", {})
        def handle_screenshot_resume_capture(ws, _) = emit(ws, "CaptureResumed", "Screenshot", {})
      end
    end
  end
end
