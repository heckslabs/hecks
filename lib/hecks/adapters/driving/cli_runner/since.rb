# frozen_string_literal: true

require "digest"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # `--since[=<hash>]`, which a caller that asks the same query again gives so the answer
        # costs a line when nothing changed. Bare `--since` ends the answer with a short hash of it;
        # `--since=<hash>` answers `unchanged since <hash>` when the new answer hashes the same, and
        # the answer with its new hash when it does not. Only a query answers this way: a command
        # always prints what it did. The launcher keeps nothing between lines; the caller carries
        # the hash. Timestamps are left out of the hash, so a clock tick alone is not a change.
        module Since
          FLAG = /\A--since(?:=(?<hash>[0-9a-f]{1,16}))?\z/
          # An ISO 8601 time, which moves on every call without the answer meaning anything new.
          MOMENT = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?/
          DIGEST_LENGTH = 8

          # Takes the flag out of a line.
          #
          # @param argv [Array<String>] the words the launcher was given
          # @return [Array(Hash, Array<String>)] the flag as `{ given: Boolean, hash: String|nil }`
          #   and the words without it
          def split_since(argv)
            flag = argv.filter_map { |word| FLAG.match(word) }.last
            [{ given: !flag.nil?, hash: flag && flag[:hash] }, argv.grep_v(FLAG)]
          end

          # The answer a query gets under the flag.
          #
          # @param answer [Array(String, Integer)] the text and the `ExitStatus`
          # @param since [Hash] what {#split_since} took from the line
          # @return [Array(String, Integer)] the answer: a line when unchanged, else the text with
          #   its hash after it
          def answer_since(answer, since)
            text, status = answer
            digest = digest_of(text)
            return ["unchanged since #{digest}", status] if since[:hash] == digest

            ["#{text.to_s.chomp}\n[since: #{digest}]", status]
          end

          # @param text [String] an answer
          # @return [String] a short hash of it with its moments left out
          def digest_of(text)
            Digest::SHA256.hexdigest(text.to_s.gsub(MOMENT, "")).slice(0, DIGEST_LENGTH)
          end
        end
      end
    end
  end
end
