require_relative "../../declared_replies"

module Hecks
  module Bluebook
    module DSL
      # The `replies` and `refuses` rows of a declared adapter, as the Rust parser reads them from
      # its `.adapter` file: the one reader of a declared adapter's data, so no Ruby evaluates it.
      module DeclaredRows
        module_function

        # @param path [String, nil] the `.adapter` file
        # @param name [String] the adapter whose rows are wanted
        # @return [Array<Hash{String => Object}>] its rows, in file order
        # @raise [Malformed] if the file is unknown, the parser refuses it, or it lacks the adapter
        def read(path, name)
          raise Malformed, "#{name} declares replies, but its .adapter file is not known" unless path

          adapter = parsed(path).find { |declared| declared["name"] == name } or
            raise Malformed, "#{path} declares no adapter named #{name}"
          adapter.fetch("replies", [])
        end

        # @return [Array<Hash>] every adapter `hecks-parse adapter` reads from the file
        # @raise [Malformed] with the parser's own refusal
        def parsed(path)
          DeclaredReplies.adapters(path)
        rescue DeclaredReplies::Unread => e
          raise Malformed, e.message
        end
      end
    end
  end
end
