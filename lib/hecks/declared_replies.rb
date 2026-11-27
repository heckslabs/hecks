require "json"
require "open3"
require_relative "sentence_form"

module Hecks
  # The Rust parser's two answers about a declared adapter: the `replies` and `refuses` rows it
  # reads from an `.adapter` file, and the answer those rows give one asking. Rust is the one
  # reader of a declared adapter's rows, so no Ruby evaluates or matches them; this module only
  # carries the request to `hecks-parse` and the answer back.
  module DeclaredReplies
    # Raised when `hecks-parse` refuses the file or cannot be run, with its own words.
    class Unread < StandardError; end

    module_function

    # @param path [String] the `.adapter` file
    # @return [Array<Hash{String => Object}>] each adapter the file declares, as `hecks-parse
    #   adapter` prints it
    # @raise [Unread] with the parser's refusal
    def adapters(path) = JSON.parse(parse("adapter", path))

    # @param path [String] the `.adapter` file
    # @param name [String] the declared adapter
    # @param ask [String] the ask or query its rows name
    # @param asked [Hash] the asked values, as plain data
    # @return [Hash{String => Object}] `{"answer" => ...}`, or `{"refused" => "why"}`
    # @raise [Unread] with the parser's refusal
    def answer(path, name, ask, asked) = JSON.parse(parse("reply", path, name, ask, stdin_data: JSON.generate(asked)))

    def parse(*, stdin_data: "")
      out, err, status = Open3.capture3(SentenceForm.binary, *, stdin_data:)
      raise Unread, err.strip unless status.success?

      out
    end
  end
end
