# Hecks::Capabilities::LiveReload::Watcher
#
# Polls configured directories for .bluebook / .hecksagon / .world file changes,
# re-evaluates modified files, and publishes a BluebookReloaded event
# on the runtime's event bus. Uses Ruby's built-in File.stat for mtime
# checking — no external gem dependencies.
#
# The watcher debounces rapid changes so that multiple file saves within
# the debounce window trigger only a single reload cycle.
#
#   watcher = LiveReload::Watcher.new(runtime, watch_dirs: ["hecks"], debounce: 0.5)
#   watcher.start_async   # => Thread (non-blocking)
#   watcher.start          # blocks the calling thread
#   watcher.stop           # signals the polling loop to exit
#

module Hecks
  module Capabilities
    module LiveReload
      # Hecks::Capabilities::LiveReload::Watcher
      #
      # Polls for .bluebook / .hecksagon / .world file changes and reloads the domain IR.
      #
      class Watcher
        WATCH_EXTENSIONS = %w[.bluebook .hecksagon .world].freeze

        attr_reader :watch_dirs, :debounce

        # @param runtime [Object] the booted Hecks runtime
        # @param watch_dirs [Array<String>] directories to watch (relative to pwd)
        # @param debounce [Float] seconds to wait before reloading after a change
        def initialize(runtime, watch_dirs: ["hecks"], debounce: 0.5)
          @runtime    = runtime
          @watch_dirs = watch_dirs
          @debounce   = debounce
          @running    = false
          @mtimes     = {}
          @root       = Dir.pwd
        end

        # Start polling. Blocks the calling thread.
        #
        # @return [void]
        def start
          @running = true
          seed_mtimes
          poll_loop
        end

        # Start polling in a background thread.
        #
        # @return [Thread]
        def start_async
          Thread.new { start }
        end

        # Signal the polling loop to stop.
        #
        # @return [void]
        def stop
          @running = false
        end

        private

        def poll_loop
          while @running
            changed = detect_changes
            if changed.any?
              sleep(@debounce)
              # Re-scan after debounce to catch additional changes in the window
              detect_changes
              reload(changed)
            end
            sleep(@debounce)
          end
        end

        def detect_changes
          changed = []
          watched_files.each do |path|
            mtime = safe_mtime(path)
            next unless mtime

            if @mtimes[path] != mtime
              @mtimes[path] = mtime
              changed << path
            end
          end
          changed
        end

        def seed_mtimes
          watched_files.each do |path|
            @mtimes[path] = safe_mtime(path)
          end
        end

        def watched_files
          @watch_dirs.flat_map do |dir|
            full = File.expand_path(dir, @root)
            next [] unless File.directory?(full)

            Dir.glob(File.join(full, "**", "*")).select do |f|
              WATCH_EXTENSIONS.include?(File.extname(f))
            end
          end
        end

        def reload(changed_paths)
          changed_paths.each do |path|
            Kernel.load(path)
          rescue => e
            warn "[LiveReload] Error loading #{path}: #{e.message}"
          end
          publish_event(changed_paths)
        end

        def publish_event(changed_paths)
          event = BluebookReloaded.new(changed_paths)
          @runtime.event_bus.publish(event)
        rescue => e
          warn "[LiveReload] Error publishing reload event: #{e.message}"
        end

        def safe_mtime(path)
          File.stat(path).mtime
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
      end

      # Hecks::Capabilities::LiveReload::BluebookReloaded
      #
      # Domain event published when .bluebook / .hecksagon / .world files are reloaded.
      #
      class BluebookReloaded
        attr_reader :changed_paths, :reloaded_at

        # @param changed_paths [Array<String>] absolute paths of changed files
        def initialize(changed_paths)
          @changed_paths = changed_paths
          @reloaded_at   = Time.now
        end

        def to_h
          { changed_paths: @changed_paths, reloaded_at: @reloaded_at.iso8601 }
        end
      end
    end
  end
end
