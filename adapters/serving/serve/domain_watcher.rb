module Hecks
  module HTTP
    # Hecks::HTTP::DomainWatcher
    #
    # Polls the domain source directory for file changes using mtime comparison.
    # When a change is detected, invokes a callback (typically DomainServer#reload!).
    # Runs in a background thread and requires no gem dependencies beyond stdlib.
    #
    #   watcher = DomainWatcher.new("/path/to/domain", interval: 1) { puts "changed!" }
    #   watcher.start
    #   watcher.stop
    #
    class DomainWatcher
      # @return [String] the directory being watched
      attr_reader :watch_dir

      # @return [Numeric] polling interval in seconds
      attr_reader :interval

      # Initialize a watcher for a directory.
      #
      # @param watch_dir [String] the directory to poll for changes
      # @param interval [Numeric] seconds between polls (default: 1)
      # @yield called when a file change is detected
      # @return [DomainWatcher] a new watcher instance (not yet started)
      def initialize(watch_dir, interval: 1, &on_change)
        @watch_dir = watch_dir
        @interval = interval
        @on_change = on_change
        @snapshot = {}
        @running = false
        @thread = nil
      end

      # Start polling in a background thread.
      #
      # Takes an initial snapshot of file mtimes, then polls at the configured
      # interval. When any file's mtime changes (or files are added/removed),
      # invokes the on_change callback and takes a fresh snapshot.
      #
      # @return [Thread] the background polling thread
      def start
        @snapshot = take_snapshot
        @running = true
        @thread = Thread.new { poll_loop }
        @thread.abort_on_exception = true
        @thread
      end

      # Stop the polling thread.
      #
      # @return [void]
      def stop
        @running = false
        @thread&.join(2)
      end

      # Check if the watcher is currently running.
      #
      # @return [Boolean]
      def running?
        @running
      end

      private

      # The main polling loop. Sleeps for the interval, then compares
      # the current snapshot to the previous one. Fires callback on diff.
      #
      # @return [void]
      def poll_loop
        while @running
          sleep @interval
          current = take_snapshot
          if current != @snapshot
            @snapshot = current
            @on_change&.call
          end
        end
      end

      # Build a hash of relative file paths to their mtime for all Ruby files
      # in the watch directory.
      #
      # @return [Hash{String => Time}] path-to-mtime mapping
      def take_snapshot
        return {} unless File.directory?(@watch_dir)

        Dir[File.join(@watch_dir, "**", "*.rb")].sort.each_with_object({}) do |f, h|
          h[f] = File.mtime(f)
        end
      end
    end
  end
end
