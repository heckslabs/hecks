require_relative "../ports/persistence/plugins/era/expected_era"

module Hecks
  module CLI
    # The command behind `hecks check_era` and Custodian's `Host.CheckEra`: asks a running host
    # which era it reports and compares it with an allow-list file. Read-only: one GET, no writes.
    module CheckEra
      USAGE = "usage: hecks check_era <url> <expected-era-file> [--timeout=<seconds>]".freeze

      # What a check found.
      #
      # @!attribute [r] verdict
      #   @return [Runtime::EraCheck::ExpectedEra::Verdict] the era compared with the list
      # @!attribute [r] version
      #   @return [String] the gem version the host reports, empty when it reports none
      # @!attribute [r] line
      #   @return [String] the sentence `hecks check_era` prints for this finding
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
      def assess(url, file, timeout: 10)
        expected = Runtime::EraCheck::ExpectedEra
        allowed  = expected.parse(File.read(file))
        document = expected.fetch_version(url, timeout: timeout)
        verdict  = expected.verdict(document.fetch("era"), allowed)
        Finding.new(verdict, document.fetch("version"), sentence(verdict, file))
      end

      # Runs `hecks check_era`: prints the finding and answers the exit status.
      #
      # @param argv [Array<String>] the url, the allow-list file and an optional `--timeout=N`
      # @param out [IO] where a finding goes
      # @param err [IO] where a refusal goes
      # @return [Integer] 0 when the era is expected or unlisted, 1 on a mismatch, 2 on bad
      #   usage or an unreadable file, 3 when the host cannot be reached or answers no era
      def run(argv, out: $stdout, err: $stderr)
        timeout = 10
        args = argv.reject do |arg|
          next false unless arg.start_with?("--timeout=")

          timeout = arg.delete_prefix("--timeout=").to_f
          true
        end
        url, file = args
        return usage(err) unless url && file && args.size == 2 && timeout.positive?

        finding = assess(url, file, timeout: timeout)
        (finding.verdict.ok? ? out : err).puts(finding.line)
        finding.verdict.ok? ? 0 : 1
      rescue Errno::ENOENT, Errno::EACCES => e
        err.puts("cannot read #{file}: #{e.message}")
        2
      rescue Runtime::EraCheck::ExpectedEra::Unreachable, Runtime::EraCheck::ExpectedEra::BadResponse => e
        err.puts("era check failed: #{e.message}")
        3
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

      def usage(err)
        err.puts(USAGE)
        2
      end
    end
  end
end
