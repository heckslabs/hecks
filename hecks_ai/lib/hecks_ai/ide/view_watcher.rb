# Hecks::AI::IDE::ViewWatcher
#
# Watches the views directory for changes and pushes reload events.
# The reload event is cleared after 2 seconds to prevent infinite
# reload loops when the page polls after refreshing.
#
#   watcher = ViewWatcher.new(views_dir, events, mutex)
#   watcher.start  # spawns background thread
#
module Hecks
  module AI
    module IDE
      class ViewWatcher
        def initialize(views_dir, events, mutex)
          @dir = views_dir
          @events = events
          @mutex = mutex
          @mtimes = snapshot
        end

        def start
          Thread.new do
            loop do
              sleep 1
              current = snapshot
              if current != @mtimes
                @mtimes = current
                @mutex.synchronize { @events.clear }
                @mutex.synchronize { @events << '{"type":"reload"}' }
                sleep 2
                @mutex.synchronize { @events.clear }
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
