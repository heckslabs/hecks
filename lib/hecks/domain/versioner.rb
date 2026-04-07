require "date"
  # Hecks::Versioner
  #
  # Calendar-based versioning for domain gems. Each build stamps the current
  # date with an auto-incrementing build number: 2026.03.20.1, 2026.03.20.2, etc.
  #
  # The version tells you when the domain was defined, not what changed.
  # No manual bumping -- every build gets the next number automatically.
  # The build number resets to 1 when the date changes.
  #
  # The version is persisted to a +.hecks_version+ file in the project directory.
  #
  #   versioner = Hecks::Versioner.new(".")
  #   versioner.current   # => "2026.03.20.1"
  #   versioner.next      # => "2026.03.20.2"
  #   versioner.next      # => "2026.03.20.3"
  #   # next day:
  #   versioner.next      # => "2026.03.21.1"
  #

module Hecks
  class Versioner
    # Filename used to persist the current version.
    VERSION_FILE = ".hecks_version"

    # @param path [String] directory path where the version file is stored
    def initialize(path)
      @path = path
      @version_file = File.join(path, VERSION_FILE)
    end

    # Read the current version from the version file.
    #
    # @return [String, nil] the current CalVer string (e.g., "2026.03.20.1"),
    #   or nil if no version file exists yet
    def current
      if File.exist?(@version_file)
        File.read(@version_file).strip
      else
        nil
      end
    end

    # Compute and persist the next version. If the current version is from
    # today, increments the build number. Otherwise, starts at build 1 for
    # the new date.
    #
    # @return [String] the new CalVer string (e.g., "2026.03.20.2")
    def next
      today = Date.today.strftime("%Y.%m.%d")
      prev = current

      build = if prev && prev.start_with?(today)
                # Same day — increment the build number
                prev.split(".").last.to_i + 1
              else
                1
              end

      version = "#{today}.#{build}"
      File.write(@version_file, version)
      version
    end
  end
end
