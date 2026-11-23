require "cgi"

module Hecks
  module Adapters
    module Driving
      module Clock
        # Projects a domain's clocks to process files, one process per clock (ADR 0184, decided
        # 4): a Procfile line each, and a launchd property list each that keeps the clock alive.
        # It writes nothing; the text is the answer.
        module LaunchFiles
          # The boundary inside a CamelCase name where a Procfile name takes an underscore.
          CAMEL_CASE_BOUNDARY = /([a-z\d])([A-Z])/

          module_function

          # @param domain [String] the domain directory
          # @param names [Array<String>] the clocks' names
          # @param launcher [String] the hecks launcher to run
          # @return [String] one Procfile line per clock
          def procfile(domain, names, launcher: "hecks")
            names.map { |name| "#{process_name(name)}: #{command(domain, name, launcher)}" }.join("\n")
          end

          # @param domain [String] the domain directory
          # @param name [String] the clock's name
          # @param launcher [String] the hecks launcher to run
          # @return [String] a launchd property list that runs the clock and restarts it if it dies
          def plist(domain, name, launcher: "hecks")
            <<~XML
              <?xml version="1.0" encoding="UTF-8"?>
              <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
              <plist version="1.0">
              <dict>
                <key>Label</key>
                <string>#{CGI.escapeHTML(label(domain, name))}</string>
                <key>ProgramArguments</key>
                <array>
                  <string>/bin/zsh</string>
                  <string>-lc</string>
                  <string>#{CGI.escapeHTML(command(domain, name, launcher))}</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
              </dict>
              </plist>
            XML
          end

          # @return [String] the launcher call that runs one clock
          def command(domain, name, launcher)
            "#{launcher} Clock.run! domain.value=#{domain} clock.value=#{name}"
          end

          # @return [String] the clock's name as a Procfile process name
          def process_name(name) = name.gsub(CAMEL_CASE_BOUNDARY, '\1_\2').downcase

          # @return [String] the launchd label, unique per domain directory and clock
          def label(domain, name) = "dev.hecks.clock.#{File.basename(domain)}.#{process_name(name)}"
        end
      end
    end
  end
end
