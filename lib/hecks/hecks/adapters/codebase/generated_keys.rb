# frozen_string_literal: true

require "hecks/corpus"
require_relative "tree"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `GeneratedKey` query asks of the working tree: the hash of everything
      # regenerating some domains' Rust reads, which a cache of the generated tree is keyed on.
      #
      # The hash is `Hecks::Corpus::GeneratedKey`'s; this answers it in this process and turns a
      # refusal of a domain name into the failure a query raises.
      module GeneratedKeys
        module_function

        # @param args [Hash] the query's plain arguments: `domains` (feature names), `files`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @return [String] the hash, with each file hashed above it when `files` is true
        # @raise [ConsoleCapture::Failure] when a name is not a domain, listing the valid ones
        def report(args, tree)
          names = args[:domains]&.split(",")
          Corpus::GeneratedKey.report(names, files: args[:files] == true, root: tree.root)
        rescue Corpus::UnknownDomain => e
          raise ConsoleCapture::Failure, e.message
        end
      end
    end
  end
end
