# frozen_string_literal: true

require "cgi"
require "fileutils"
require "open3"
require "rbconfig"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class Guarding
      # The launchd job that runs the watchdog's loop: its property list, written under the launch
      # agents directory and loaded, or unloaded and removed. The job is kept alive by launchd, at
      # normal priority (never Background, so the sessions it resumes are not held on the efficiency
      # cores), and in a process tree of its own, apart from Hecks and from Claude.
      class LaunchAgent
        # The job's label, and the stem of its file.
        LABEL = "dev.hecks.watchdog"

        # The loop's code, copied into the job's home so a removed checkout does not stop it.
        LOOP_DIR = File.expand_path("loop", __dir__)

        # The property list: kept alive by launchd, started at load, at normal priority and not
        # Background, so the sessions it resumes are not held on the efficiency cores.
        PLIST = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>%<label>s</string>
            <key>ProgramArguments</key>
            <array>
          %<arguments>s
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Standard</string>
            <key>Nice</key>
            <integer>0</integer>
            <key>StandardErrorPath</key>
            <string>%<error_log>s</string>
          </dict>
          </plist>
        XML

        # @param home [String] the home directory whose launch agents and loop directory are used
        # @param runner [#call, nil] runs `launchctl` from its arguments: `[output, success]`
        def initialize(home: Dir.home, runner: nil)
          @home = home
          @runner = runner || method(:launchctl)
        end

        # @return [String] where the property list is kept
        def path = File.join(@home, "Library", "LaunchAgents", "#{LABEL}.plist")

        # @return [String] the loop's directory: its code, roster, journal and state
        def dir = File.join(@home, ".claude", "hecks-dev", "watchdog")

        # @return [String] the property list, a pure function of the home directory and the Ruby
        def plist
          arguments = [RbConfig.ruby, File.join(dir, "bin", "watch.rb"), dir]
          lines = arguments.map { |argument| "    <string>#{CGI.escapeHTML(argument)}</string>" }
          format(PLIST, label: LABEL, arguments: lines.join("\n"), error_log: File.join(dir, "watchdog.err.log"))
        end

        # Copies the loop and writes the roster, writes the property list and loads the job.
        # Unconfirmed, it writes nothing and answers the property list it would write.
        #
        # @param roster [String] the roster document the loop reads
        # @param confirm [Boolean] whether the launch agents directory may be written
        # @return [String] what was done
        # @raise [ConsoleCapture::Failure] when launchd refuses the job
        def install(roster:, confirm:)
          return "would write #{path}:\n#{plist}" unless confirm

          unload
          stage(roster)
          File.write(path, plist)
          load_job
          "armed #{LABEL}: a pass every 30s over the declared pinned sessions, journal in #{dir}"
        end

        # Unloads the job and removes its property list; the journal stays.
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

        def stage(roster)
          FileUtils.mkdir_p([File.dirname(path), File.join(dir, "bin")])
          FileUtils.cp(Dir[File.join(LOOP_DIR, "*.rb")], File.join(dir, "bin"))
          File.write(File.join(dir, "roster.json"), roster)
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
