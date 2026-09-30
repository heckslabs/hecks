require "json"
require "net/http"
require "uri"

module Hecks
  module Runtime
    module EraCheck
      # Compares a running host's reported era (`GET /version`) against an
      # allow-list file of eras that should be running, for use after a roll.
      module ExpectedEra
        # The host could not be reached, or did not answer with a `200`.
        class Unreachable < StandardError; end

        # The host answered, but not with a `/version` document carrying an era.
        class BadResponse < StandardError; end

        # What a comparison concluded.
        #
        # @!attribute [r] status
        #   @return [Symbol] `:match`, `:unlisted` (no era listed) or `:mismatch`
        # @!attribute [r] era
        #   @return [String] the era the host reported
        # @!attribute [r] allowed
        #   @return [Array<String>] the eras the list accepts
        Verdict = Struct.new(:status, :era, :allowed) do
          # Tells whether the roll is acceptable.
          #
          # @return [Boolean] true unless the reported era is off the list
          def ok? = status != :mismatch
        end

        module_function

        # Reads the eras out of an allow-list file's text.
        #
        # @param text [String] the file's contents
        # @return [Array<String>] the era ids in file order, without comments or blanks
        def parse(text)
          text.each_line.filter_map do |line|
            entry = line.strip.sub(/\s+#.*\z/, "")
            entry unless entry.empty? || entry.start_with?("#")
          end
        end

        # Builds the `/version` URL from what an operator gave.
        #
        # @param url [String] a host's base URL, or its `/version` URL itself
        # @return [String] the URL to request
        def version_url(url)
          base = url.to_s.chomp("/")
          base.end_with?("/version") ? base : "#{base}/version"
        end

        # Asks a host which era it reports.
        #
        # @param url [String] the host's base URL, or its `/version` URL
        # @param timeout [Numeric] seconds allowed for connecting and for reading
        # @return [String] the `era` the host's `/version` document carries
        # @raise [Unreachable] if the request fails or the status is not `200`
        # @raise [BadResponse] if the body is not JSON or its `era` is not a non-empty string
        def fetch_era(url, timeout: 10)
          fetch_version(url, timeout: timeout).fetch("era")
        end

        # Asks a host for its `/version` document.
        #
        # @param url [String] the host's base URL, or its `/version` URL
        # @param timeout [Numeric] seconds allowed for connecting and for reading
        # @return [Hash{String => String}] `"era"` (never empty) and `"version"` (empty when the
        #   host reports none)
        # @raise [Unreachable] if the request fails or the status is not `200`
        # @raise [BadResponse] if the body is not JSON or its `era` is not a non-empty string
        def fetch_version(url, timeout: 10)
          response = get(version_url(url), timeout)
          raise Unreachable, "#{version_url(url)} answered #{response.code}" unless response.code == "200"

          document = JSON.parse(response.body)
          era = document["era"]
          raise BadResponse, "#{version_url(url)} carries no era" unless era.is_a?(String) && !era.empty?

          { "era" => era, "version" => document["version"].to_s }
        rescue JSON::ParserError, TypeError
          raise BadResponse, "#{version_url(url)} did not answer a JSON version document"
        end

        # Compares a reported era with an allow-list.
        #
        # @param era [String] the era the host reported
        # @param allowed [Array<String>] the eras the list accepts; empty accepts any
        # @return [Verdict] `:unlisted` when the list is empty, else `:match` or `:mismatch`
        def verdict(era, allowed)
          status = if allowed.empty? then :unlisted
                   elsif allowed.include?(era) then :match
                   else :mismatch
                   end
          Verdict.new(status, era, allowed)
        end

        # Fetches the host's era and compares it with an allow-list file.
        #
        # @param url [String] the host's base URL, or its `/version` URL
        # @param file [String] path of the allow-list file
        # @param timeout [Numeric] seconds allowed for connecting and for reading
        # @return [Verdict] the comparison
        # @raise [Errno::ENOENT] if the allow-list file does not exist
        # @raise [Unreachable] see `fetch_era`
        # @raise [BadResponse] see `fetch_era`
        def check(url, file, timeout: 10)
          allowed = parse(File.read(file))
          verdict(fetch_era(url, timeout: timeout), allowed)
        end

        def get(url, timeout)
          uri = URI.parse(url)
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                              open_timeout: timeout, read_timeout: timeout) do |http|
            http.request(Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json"))
          end
        rescue SystemCallError, SocketError, Timeout::Error, IOError, URI::InvalidURIError => e
          raise Unreachable, "#{url} could not be reached: #{e.message}"
        end
        private_class_method :get
      end
    end
  end
end
