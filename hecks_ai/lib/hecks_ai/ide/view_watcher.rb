# Hecks::AI::IDE::ViewWatcher
#
# Watches the views directory for changes and pushes reload events.
# Uses a cooldown to prevent rapid-fire reloads.
#
#   watcher = ViewWatcher.new(views_dir, events, mutex)
#   watcher.start  # spawns background thread
#
module Hecks
  module AI
    module IDE
      class ViewWatcher
        def initialize(views_dir, events, mutex, screenshot_handler: nil)
          @dir = views_dir
          @events = events
          @mutex = mutex
          @screenshots = screenshot_handler
          @mtimes = snapshot
          @cooldown = false
        end

        def start
          Thread.new do
            loop do
              sleep 2
              next if @cooldown
              current = snapshot
              if current != @mtimes
                @mtimes = current
                @cooldown = true
                @screenshots&.clear_on_start
                @mutex.synchronize do
                  @events.clear
                  @events << '{"type":"reload"}'
                end
                # Cooldown: ignore changes for 5s after a reload
                Thread.new { sleep 5; @cooldown = false; @mutex.synchronize { @events.delete('{"type":"reload"}') } }
              end
            end
          end
        end

        private

        def snapshot
          Dir.glob(File.join(@dir, "**/*")).each_with_object({}) do |f, h|
            h[f] = File.mtime(f).to_i if File.file?(f)
          end
        end
      end
    end
  end
end
