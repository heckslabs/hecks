# frozen_string_literal: true

require "json"
require "open3"
require "base64"

module Hecks
  module Adapters
    # The `ClientRepo` port answered through `gh`: it creates a client's repository private and
    # writes files to it, and nothing else. No method takes a visibility, `create` always passes
    # `--private`, and every write reads the repository's visibility again and refuses unless it
    # reads as private. The command runner is the adapter's own seam, so a spec never runs `gh`.
    class ClientRepoGh
      class Refused < StandardError; end

      # What separates the runs of characters a repository name cannot hold.
      UNNAMEABLE = /[^a-z0-9]+/

      # The dashes a slug does not start or end with.
      EDGE_DASH = /\A-|-\z/

      # Runs a command and answers its output, error and whether it succeeded.
      RUNNER = ->(*argv) { Open3.capture3(*argv).then { |out, err, status| [out, err, status.success?] } }

      # @param aggregate [Object, nil] unused
      # @param runner [#call] runs an argv, answering `[output, error, success]`
      def initialize(aggregate: nil, runner: RUNNER)
        @runner = runner
      end

      # @param name [Hash, String] the client's name
      # @return [Hash] the name, once the private repository exists
      # @raise [Refused] when `gh` could not create it
      def create_private(name:, **)
        run("gh", "repo", "create", slug(name), "--private")
        { name: name }
      end

      # @return [Hash] the name, when the repository reads as private
      # @raise [Refused] when it does not
      def confirm_private(name:, **)
        visibility(name)
        { name: name }
      end

      # @return [Hash] what was asked, when the repository reads as private
      # @raise [Refused] when it does not
      def check_before_write(name:, path:, content:, **)
        visibility(name)
        { name: name, path: path, content: content }
      end

      # Writes one new file, after reading the repository's visibility again.
      #
      # @return [Hash] the name and path written
      # @raise [Refused] when the repository is not private or `gh` could not write
      def write_file(name:, path:, content:, **)
        repo = visibility(name)
        run("gh", "api", "-X", "PUT", "repos/#{repo}/contents/#{plain(path)}",
            "-f", "message=Add #{plain(path)}", "-f", "content=#{Base64.strict_encode64(plain(content))}")
        { name: name, path: path }
      end

      alias is_private confirm_private

      private

      # @return [String] the repository's owner and name, once it reads as private
      def visibility(name)
        out = run("gh", "repo", "view", slug(name), "--json", "nameWithOwner,visibility")
        found = JSON.parse(out)
        raise Refused, "#{slug(name)} is not private" unless found["visibility"].to_s.casecmp?("private")

        found["nameWithOwner"]
      end

      def run(*argv)
        out, err, ok = @runner.call(*argv)
        raise Refused, "#{argv[0..2].join(" ")}: #{err.to_s.strip}" unless ok

        out
      end

      def slug(name) = plain(name).downcase.gsub(UNNAMEABLE, "-").gsub(EDGE_DASH, "")

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
