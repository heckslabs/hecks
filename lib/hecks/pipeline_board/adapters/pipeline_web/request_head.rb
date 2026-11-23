# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The head of one HTTP request, read off its socket: the verb and target of the request line
      # and the headers, lower-cased by name.
      module RequestHead
        # @param socket [IO] the connection, read until the blank line that ends the headers
        # @return [Array] the verb, the target and the headers hash
        def self.read(socket)
          verb, target = socket.gets.to_s.split
          [verb, target, headers(socket)]
        end

        def self.headers(socket)
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            key, value = line.split(":", 2)
            headers[key.to_s.downcase] = value.to_s.strip
          end
          headers
        end
      end
    end
  end
end
