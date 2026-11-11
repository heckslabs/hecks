# frozen_string_literal: true

require "cgi"
require "fileutils"
require "open3"

module Hecks
  module Adapters
    class MainIntegration
      # The launchd job that beats the clock once a minute from outside any process of the domain,
      # so a train pull request is observed after its per-boarding chain of ticks has ended. It
      # renders the job's property list, writes it under the launch agents directory and loads it,
      # or unloads and removes it. The job dispatches `Heartbeat.Beat` and nothing else: whether a
      # beat finds a train pull request to read is the bluebook's answer, and a quiet beat is
      # refused there, so this class holds no rule about pull requests.
      class BeatSchedule
        # The job's label, and the stem of its file.
        LABEL = "dev.hecks.train-beat"

        # Seconds between two beats.
        INTERVAL = 60

        # @param root [String] the checkout whose launcher each beat dispatches through; the push
        #   train's copy by default, the one whose records a beat reads
        # @param home [String] the home directory whose launch agents and log are used
        # @param runner [#call, nil] runs `launchctl` from its argument list and answers
        #   `[output, success]`; a stand-in in specs
        def initialize(root: File.join(Dir.home, ".claude", "hecks-train"), home: Dir.home, runner: nil)
          @root = root
          @home = home
          @runner = runner || method(:launchctl)
        end

        # @return [String] where the property list is kept
        def path = File.join(@home, "Library", "LaunchAgents", "#{LABEL}.plist")

        # @return [String] the property list, a pure function of the root and the home directory
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
              <key>StartInterval</key>
              <integer>#{INTERVAL}</integer>
              <key>RunAtLoad</key>
              <false/>
              <key>ProcessType</key>
              <string>Background</string>
              <key>LowPriorityIO</key>
              <true/>
              <key>Nice</key>
              <integer>10</integer>
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
          "installed #{LABEL}: a beat every #{INTERVAL}s from #{@root}"
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

        def script
          log = File.join(@home, ".claude", "hecks-dev", "train-beat.log")
          "cd #{@root} || exit 1\nexe/hecks Heartbeat.Beat beat.value=launchd-$(date +%s) --wait > \"#{log}\" 2>&1"
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
