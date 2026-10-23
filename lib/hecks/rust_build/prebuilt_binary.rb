# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "uri"
require "hecks/vocabulary"

module Hecks
  module RustBuild
    # A binary hecks has already compiled and published, named by what went into it (ADR 0110).
    #
    # The `PrebuiltBinary` rows of the Vocabulary chapter say which binaries are published: the
    # crate to key, the Cargo binary, the target it is built for. A release tagged `<name>-<key>`
    # holds the binary and its `.sha256`; the key is a hash of the crate's build inputs, so the
    # same bytes are the same release, whichever commit they come from. `fetch` downloads it and
    # checks its hash, and answers nil on any miss (not published yet, no network, a hash that
    # does not match) so a caller compiles as it always did. `HECKS_PREBUILT=off` turns the
    # download off.
    module PrebuiltBinary
      # Where releases are published.
      REPOSITORY = "heckslabs/hecks"

      # Left out of the key: Cargo's own output, and files that are never part of the binary.
      EXCLUDED = %w[target tests .gitignore].freeze

      MAX_REDIRECTS = 5

      module_function

      # @param name [String] a `PrebuiltBinary` row's name
      # @return [Hash{String => String}] the row
      # @raise [KeyError] when no row has the name
      def row(name)
        Hecks::Vocabulary.rows("PrebuiltBinary").find { |found| found["name"] == name } or
          raise KeyError, "no PrebuiltBinary row named #{name.inspect}"
      end

      # @param crate [String] a row's crate, the directory under the checkout (`rust/host`)
      # @param target [String] the triple the caller builds for
      # @return [String, nil] the name of the row that publishes the crate for the target,
      #   nil when none does
      def name_for(crate, target)
        found = Hecks::Vocabulary.rows("PrebuiltBinary").find { |row| row["crate"] == crate && row["target"] == target }
        found&.fetch("name")
      end

      # @param crate [String] a row's crate
      # @param crate_dir [String] the crate's directory
      # @param target [String] the triple the caller builds for
      # @param into [String] the file to write the binary to
      # @return [String, nil] `into`, or nil when no row publishes the crate for the target
      #   or `fetch` misses
      def fetch_for(crate, crate_dir, target:, into:)
        name = name_for(crate, target) or return
        fetch(name, crate_dir, target: target, into: into)
      end

      # @param crate_dir [String] the crate's directory
      # @return [String] a hash of every file that goes into the build: each path and its bytes, in
      #   path order, so it does not depend on the checkout it is read from
      def key(crate_dir)
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: crate_dir).sort.select do |path|
          File.file?(File.join(crate_dir, path)) && !EXCLUDED.include?(path.split("/").first)
        end
        digest = Digest::SHA256.new
        files.each { |path| digest << "#{path}\0#{File.binread(File.join(crate_dir, path))}\0" }
        digest.hexdigest[0, 24]
      end

      # @param name [String] a row's name
      # @param key [String] the crate's key
      # @return [String] the release tag
      def tag(name, key) = "#{name}-#{key}"

      # @param name [String] a row's name
      # @return [String] the file the release holds the binary as
      def asset(name)
        found = row(name)
        "#{found["executable"]}-#{found["target"]}"
      end

      # @param name [String] a row's name
      # @param crate_dir [String] the crate's directory
      # @param target [String] the triple the caller builds for
      # @param into [String] the file to write the binary to
      # @return [String, nil] `into`, or nil when the binary is not published for this target or
      #   could not be fetched and verified
      def fetch(name, crate_dir, target:, into:)
        return if ENV["HECKS_PREBUILT"] == "off" || row(name)["target"] != target

        body = verified(name, crate_dir) or return
        FileUtils.mkdir_p(File.dirname(into))
        File.binwrite(into, body)
        File.chmod(0o755, into)
        puts "== downloaded the prebuilt #{asset(name)} (#{tag(name, key(crate_dir))}); nothing compiled =="
        into
      rescue SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
        nil
      end

      # @return [String, nil] the published binary, nil unless its bytes hash to the published
      #   sha256
      def verified(name, crate_dir)
        base = "https://github.com/#{REPOSITORY}/releases/download/#{tag(name, key(crate_dir))}/#{asset(name)}"
        expected = get("#{base}.sha256")&.split&.first
        body = expected && get(base)
        body if body && Digest::SHA256.hexdigest(body) == expected
      end

      # @return [String, nil] the body at the URL, following redirects, nil unless it answers 200
      def get(url, redirects = MAX_REDIRECTS)
        response = Net::HTTP.get_response(URI(url))
        return response.body if response.is_a?(Net::HTTPSuccess)
        return get(response["location"], redirects - 1) if response.is_a?(Net::HTTPRedirection) && redirects.positive?

        nil
      end
    end
  end
end
