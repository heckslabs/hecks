# frozen_string_literal: true

require "json"
require "open3"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    # The `Cache` port's adapter for GitHub Actions: answers `Corpus`'s `Lookup` query by asking
    # `gh` whether the repository's cache holds an entry under the key.
    class CiCache
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout `gh` runs in; this repository when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || File.expand_path("../../../..", __dir__)
      end

      # @param key [Hash, String] the cache key, as the generated-rust action names it
      # @return [Hash] `text:` a JSON document: whether the key is held, and its size when it is
      # @raise [Runtime::GivenNotMet] when `gh` cannot list the cache
      def lookup(key:)
        name = key.is_a?(Hash) ? key.values.first : key
        entries = JSON.parse(list(name.to_s))
        { text: JSON.generate(hit: !entries.empty?, bytes: entries.first&.fetch("sizeInBytes")) }
      end

      private

      def list(name)
        out, err, status = Open3.capture3("gh", "cache", "list", "--key", name, "--json", "key,sizeInBytes",
                                          chdir: @root)
        raise Runtime::GivenNotMet, "gh could not list the cache: #{err.lines.first&.strip}" unless status.success?

        out
      end
    end
  end
end
