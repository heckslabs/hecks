# frozen_string_literal: true

require "cgi"
require "fileutils"
require "open3"
require_relative "local_copy"

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

        # The step that keeps the copy at local main, as plain shell so it runs on a copy that
        # predates any code of the domain: only a detached copy with no tracked change whose
        # head is an ancestor of main moves, forward to main; a failed step never stops the beat.
        FOLLOW_MAIN = "{ ! git symbolic-ref -q HEAD >/dev/null 2>&1 && git diff --quiet HEAD && " \
                      "git merge-base --is-ancestor HEAD main && git checkout -q --detach main; } 2>/dev/null; true"

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

        # The beat's lock: held by the job's shell for as long as its beat runs, so the next tick,
        # finding it held, ends at once instead of starting a second beat on top of a slow one. The
        # file is made first, because the lock does not create it; a killed shell frees the lock.
        def lock = dev_file("train-beat.lock")

        # Where a tick that found the lock held says it was skipped, so a beat that outruns its
        # interval is seen and never stacked.
        def overrun = dev_file("train-beat.overrun.log")

        def dev_file(name) = File.join(@home, ".claude", "hecks-dev", name)

        def script
          "cd #{@root} || exit 1\n" \
            "mkdir -p \"#{File.dirname(lock)}\" && : >> \"#{lock}\"\n" \
            "zmodload zsh/system && zsystem flock -t 0 \"#{lock}\" 2>/dev/null || #{skipped}\n" \
            "#{FOLLOW_MAIN}\n" \
            "#{LocalCopy.step}\n" \
            "exe/hecks Heartbeat.Beat! beat=launchd-$(date +%s) --wait > \"#{dev_file("train-beat.log")}\" 2>&1"
        end

        def skipped
          "{ echo \"$(date -u +%FT%TZ) beat skipped: the beat before it still runs\" >> \"#{overrun}\"; exit 0; }"
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
