# frozen_string_literal: true

require "cgi"
require "fileutils"
require "open3"
require_relative "job_priority"

module Hecks
  module Adapters
    class MainIntegration
      # The launchd job that keeps a Claude daemon up at normal priority. launchd starts it, so the
      # daemon and every session it hosts inherit Standard QoS and nice 0, never the beat's
      # Background or niced scheduling that pins them to the efficiency cores. It renders the job's
      # property list, writes it under the launch agents directory and loads it, or unloads and
      # removes it. Installing replaces a job of the same label already loaded.
      class ClaudeDaemonSchedule
        # The job's label, and the stem of its file.
        LABEL = "dev.hecks.claude-daemon"

        # Seconds launchd waits before it starts the job again after it exits.
        THROTTLE = 60

        # The world verb that declares the job's scheduling.
        VERB = "claude_daemon_job"

        # @param home [String] the home directory whose launch agents and log are used
        # @param priority [JobPriority] how the job is scheduled: Standard at nice 0 by default
        # @param runner [#call, nil] runs `launchctl` from its argument list and answers
        #   `[output, success]`; a stand-in in specs
        def initialize(home: Dir.home, priority: JobPriority.new(nice: 0), runner: nil)
          @home = home
          @priority = priority
          @runner = runner || method(:launchctl)
        end

        # @return [String] where the property list is kept
        def path = File.join(@home, "Library", "LaunchAgents", "#{LABEL}.plist")

        # @return [String] the property list, a pure function of the home and priority
        def plist
          <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>#{LABEL}</string>
              <key>ProgramArguments</key>
              <array>
                <string>/bin/zsh</string>
                <string>-lc</string>
                <string>#{CGI.escapeHTML(script)}</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
              <key>KeepAlive</key>
              <true/>
              <key>ThrottleInterval</key>
              <integer>#{THROTTLE}</integer>
              <key>StandardOutPath</key>
              <string>#{log}</string>
              <key>StandardErrorPath</key>
              <string>#{log}</string>
              #{@priority.keys}
            </dict>
            </plist>
          XML
        end

        # Writes the property list and loads the job, replacing a job already loaded. Unconfirmed,
        # it writes nothing and answers the property list it would write.
        #
        # @param confirm [Boolean] whether the launch agents directory may be written
        # @return [String] what was done
        # @raise [ConsoleCapture::Failure] when launchd refuses the job
        def install(confirm:)
          return "would write #{path}:\n#{plist}" unless confirm

          unload
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, plist)
          load_job
          "installed #{LABEL}: a Claude daemon kept up at normal priority"
        end

        # Unloads the job and removes its property list.
        #
        # @param confirm [Boolean] whether the launch agents directory may be written
        # @return [String] what was done
        def uninstall(confirm:)
          return "would remove #{path}" unless confirm
          return "#{LABEL} is not installed" unless File.file?(path)

          unload
          File.delete(path)
          "removed #{LABEL}"
        end

        private

        def log = File.join(@home, ".claude", "hecks-dev", "claude-daemon.log")

        # Ends at once when a daemon answers, so launchd's next start is the poll; otherwise this
        # process becomes the daemon, with no `nice` wrapper in front of it.
        def script
          claude = "\"$HOME/.local/bin/claude\""
          "#{claude} daemon status >/dev/null 2>&1 || exec #{claude} daemon run"
        end

        def domain = "gui/#{Process.uid}"

        def unload = @runner.call(["launchctl", "bootout", "#{domain}/#{LABEL}"])

        def load_job
          out, ok = @runner.call(["launchctl", "bootstrap", domain, path])
          raise ConsoleCapture::Failure, "launchctl refused #{LABEL}: #{out.to_s.strip}" unless ok
        end

        def launchctl(argv)
          out, status = Open3.capture2e(*argv)
          [out, status.success?]
        end
      end
    end
  end
end
