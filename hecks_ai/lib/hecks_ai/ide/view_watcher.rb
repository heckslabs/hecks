# Hecks::AI::IDE::ViewWatcher
#
# Watches the views directory for changes and pushes reload events.
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
