# frozen_string_literal: true

require "digest"

module Hecks
  module Adapters
    # The keys of the `RedSpec` rows a run reader files. A key is a readable slug of what is red
    # and a digest of the exact text, so two spec paths never share a key: separators stay distinct
    # (`__`), and paths differing only in case or punctuation differ in the digest.
    module RunKeys
      # The `.rb` ending of a spec path, left off its key.
      RUBY_SUFFIX = ".rb"

      # Runs of characters a Work key does not hold.
      KEY_BREAK = /[^a-zA-Z0-9_]+/

      # Hex digits of the exact text's digest a key ends with.
      DIGEST_LENGTH = 10

      module_function

      # @param path [String] a spec path such as `spec/a/b_spec.rb`
      # @return [String] `red-<readable slug>-<digest>`
      def spec(path) = build(path.delete_suffix(RUBY_SUFFIX).gsub("/", "__"), path)

      # @param job [String] the name of a spec job that failed with no failing example in its log
      # @return [String] `red-job-<readable slug>-<digest>`
      def job(job) = build("job-#{job}", job)

      # @return [String] the key for a readable slug and the exact text it stands for
      def build(slug, exact)
        "red-#{slug.gsub(KEY_BREAK, "-").downcase}-#{Digest::SHA256.hexdigest(exact)[0, DIGEST_LENGTH]}"
      end
    end
  end
end
