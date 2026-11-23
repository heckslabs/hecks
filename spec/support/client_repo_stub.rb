# frozen_string_literal: true

module Hecks
  module Adapters
    # A stand-in for the `ClientRepo` port that every Clients spec binds: it keeps the repositories
    # and the files written to them in memory, and runs nothing. Its state is on the class, because
    # the runtime builds an adapter afresh for each ask; a spec calls {reset!} first and may call
    # {visibility=} to make a repository public, so a refusal can be seen.
    class ClientRepoStub
      Refused = Class.new(StandardError)

      class << self
        # @return [Hash{String => Hash{String => String}}] files written, by repository then path
        attr_reader :repos

        # @return [String] what a repository reads as: "private" or "public"
        attr_accessor :visibility

        # Forgets every repository and makes the next one private.
        def reset!
          @repos = {}
          @visibility = "private"
        end
      end

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil); end

      # @return [Hash] the name, once the repository exists, always private
      def create_private(name:, **)
        self.class.repos[plain(name)] ||= {}
        { name: name }
      end

      # @return [Hash] the name, when the repository reads as private
      # @raise [Refused] when it does not
      def is_private(name:, **)
        raise Refused, "the repository is not private" unless private?(name)

        { name: name }
      end

      # @return [Hash] what was asked, when the repository reads as private
      # @raise [Refused] when it does not
      def check_before_write(name:, path:, content:, **)
        is_private(name: name)
        { name: name, path: path, content: content }
      end

      # Writes the file, after reading the repository's visibility again.
      #
      # @return [Hash] what was written
      # @raise [Refused] when the repository does not read as private
      def write_file(name:, path:, content:, **)
        is_private(name: name)
        self.class.repos.fetch(plain(name))[plain(path)] = plain(content)
        { name: name, path: path }
      end

      private

      def private?(name) = self.class.repos.key?(plain(name)) && self.class.visibility == "private"

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
