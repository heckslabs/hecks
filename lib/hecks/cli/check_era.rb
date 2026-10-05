require_relative "../ports/persistence/plugins/era/expected_era"

module Hecks
  module CLI
    # The check behind Custodian's `Host.CheckEra`: asks a running host which era it reports and
    # compares it with an allow-list file. Read-only: one GET, no writes.
    module CheckEra
      # What a check found.
      #
      # @!attribute [r] verdict
      #   @return [Runtime::EraCheck::ExpectedEra::Verdict] the era compared with the list
      # @!attribute [r] version
      #   @return [String] the gem version the host reports, empty when it reports none
      # @!attribute [r] line
      #   @return [String] the sentence the check reports for this finding
      Finding = Struct.new(:verdict, :version, :line)

      module_function

      # Fetches the host's `/version` and compares its era with the allow-list file.
      #
      # @param url [String] the host's base URL, or its `/version` URL
      # @param file [String] path of the allow-list file
      # @param timeout [Numeric] seconds allowed for connecting and for reading
      # @return [Finding] the comparison, whether or not the era is listed
      # @raise [Errno::ENOENT, Errno::EACCES] if the file cannot be read
      # @raise [Runtime::EraCheck::ExpectedEra::Unreachable] if the host cannot be reached
      # @raise [Runtime::EraCheck::ExpectedEra::BadResponse] if it answers no era
      def assess(url, file, timeout:)
        expected = Runtime::EraCheck::ExpectedEra
        allowed  = expected.parse(File.read(file))
        document = expected.fetch_version(url, timeout: timeout)
        verdict  = expected.verdict(document.fetch("era"), allowed)
        Finding.new(verdict, document.fetch("version"), sentence(verdict, file))
      end

      # @param verdict [Runtime::EraCheck::ExpectedEra::Verdict] the comparison
      # @param file [String] the allow-list file, named in the sentence
      # @return [String] the one line that says what the comparison found
      def sentence(verdict, file)
        case verdict.status
        when :match
          "era #{verdict.era} is expected (#{verdict.allowed.join(', ')})"
        when :unlisted
          "host reports era #{verdict.era}; #{file} lists no era, so nothing was compared"
        else
          "host reports era #{verdict.era}, which is not in #{file} (expected: #{verdict.allowed.join(', ')})"
        end
      end
    end
  end
end
