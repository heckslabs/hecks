require "json"
require_relative "../../../runtime/errors"

module Hecks
  module Adapters
    module Driving
      module Cli
        # One JSON document on standard input that a launcher's arguments may read from by pointer
        # (ADR 0175): `name=@stdin:/transcript_path` takes that field of the document as the value,
        # so a host hook can hand its payload to a command without a script of its own. The document
        # is read once, and only when a word asks for it, so a launcher waiting at a terminal never
        # blocks on stdin it does not use.
        class StdinSource
          # What a value starts with when it is read from the document.
          PREFIX = "@stdin:".freeze

          # @param input [IO, #read] where the document comes from; `$stdin` for a launcher
          def initialize(input)
            @input = input
          end

          # The word with its `@stdin:` value replaced by the field it points at; the word unchanged
          # when it reads nothing; nil when the field is absent, so the argument is left out and the
          # command's own rules refuse it by name if it was needed.
          #
          # @param pair [String] one `name=value` word
          # @return [String, nil] the word to parse, or nil to leave the argument out
          # @raise [Runtime::NotFound] if the document is unreadable or stdin is a terminal
          # @raise [Runtime::TypeMismatch] if the field holds an object, which no argument takes
          def resolve(pair)
            name, value = pair.split("=", 2)
            return pair unless value&.start_with?(PREFIX)

            found = point(value.delete_prefix(PREFIX))
            found.nil? ? nil : "#{name}=#{word(found, name)}"
          end

          private

          def document = (@document ||= read)

          def read
            raise Runtime::NotFound, "an argument reads @stdin:, but stdin is a terminal" if terminal?

            JSON.parse(@input.read.to_s)
          rescue JSON::ParserError => e
            raise Runtime::NotFound, "stdin is not one JSON document: #{e.message[0, 80]}"
          end

          def terminal? = @input.respond_to?(:tty?) && @input.tty?

          # The field a JSON pointer names: `~1` is a slash and `~0` a tilde in a key, and an
          # array is indexed by its position. Nil when any step finds nothing.
          def point(pointer)
            keys = pointer.split("/").drop(1).map { |key| key.gsub("~1", "/").gsub("~0", "~") }
            keys.reduce(document) { |node, key| step(node, key) }
          end

          def step(node, key)
            return node[key] if node.is_a?(Hash)
            return node[Integer(key, exception: false) || node.size] if node.is_a?(Array)

            nil
          end

          # A field as a command-line value: a scalar as its text, a list as its items joined by
          # commas, which a list argument splits again.
          def word(found, name)
            raise Runtime::TypeMismatch, "#{name} reads an object from stdin; point at one of its fields" if found.is_a?(Hash)

            found.is_a?(Array) ? found.join(",") : found.to_s
          end
        end
      end
    end
  end
end
