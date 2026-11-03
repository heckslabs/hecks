# frozen_string_literal: true

module Hecks
  module Translation
    # The edge files of a domain's `translations/` directory, read by their headers.
    #
    # A header names the domain and the two shape labels an edge leads between, so a file is found
    # without loading it: the writer needs to know which files a chain uses before it changes any.
    module EdgeFiles
      # One edge file: where it is and the header it declares.
      Found = Struct.new(:path, :domain, :from, :to, keyword_init: true)

      HEADER = /^Hecks\.data_translation\s+"(?<domain>[^"]+)",\s*from:\s*"(?<from>[^"]+)",\s*to:\s*"(?<to>[^"]+)"/

      module_function

      # @param directory [String] the domain's bluebook directory
      # @return [Array<Found>] every `translations/*.bluebook` file whose header parses, by path
      def scan(directory)
        Dir[File.join(directory, "translations", "*.bluebook")].filter_map do |path|
          match = HEADER.match(File.read(path))
          Found.new(path: path, domain: match[:domain], from: match[:from], to: match[:to]) if match
        end
      end

      # The files of the edges a composed chain replaces: each leads to a shape the chain passes
      # through before its last step, so only the chain used it.
      #
      # @param directory [String] the domain's bluebook directory
      # @param domain [String] the domain whose edges count
      # @param chain [Array<Bluebook::Translation>] the chain being composed, in order
      # @return [Array<String>] the paths to delete
      def stale(directory, domain:, chain:)
        intermediates = chain[0...-1].map(&:to)
        scan(directory).filter_map do |found|
          found.path if found.domain == domain && intermediates.include?(found.to)
        end
      end

      # @param directory [String] the domain's bluebook directory
      # @param from [String] the shape label the composed edge leaves
      # @param to [String] the shape label the composed edge reaches
      # @return [String] the path the composed edge is written to
      def path_for(directory, from:, to:)
        File.join(directory, "translations", "2-#{from}-to-#{to}.bluebook")
      end
    end
  end
end
