# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class GitLanding
      # The one-way mailbox a ticket owns: a named pipe the ticket's owner blocks on and the train
      # writes to when it has settled that ticket's branch for it.
      #
      # The owner keeps the pipe open for reading and writing from the moment the ticket exists,
      # so a
      # verdict written before the owner starts to read is held by the pipe, never lost.
      class Verdict
        # @param path [String] where the pipe is made
        # @return [Verdict] the mailbox, open and empty
        def self.create(path)
          File.mkfifo(path)
          new(path, File.open(path, File::RDWR))
        end

        # Hands a verdict to the owner of the pipe at `path`, when the owner is still there.
        #
        # @param path [String] the pipe
        # @param payload [Hash] what the owner is told
        # @return [void]
        def self.deliver(path, payload)
          File.open(path, File::WRONLY | File::NONBLOCK) { |pipe| pipe.write("#{JSON.generate(payload)}\n") }
        rescue Errno::ENXIO, Errno::ENOENT
          nil
        end

        # @param path [String] the pipe
        # @param io [IO, nil] the owner's open end
        def initialize(path, io)
          @path = path
          @io = io
        end

        # Blocks until a verdict arrives; no polling.
        #
        # @return [Hash, nil] what the train delivered, nil when the pipe closed
        def read
          line = @io.gets
          line && JSON.parse(line, symbolize_names: true)
        rescue IOError
          nil
        end

        # @return [void]
        def close
          @io&.close
        end

        # @return [void]
        def remove
          File.delete(@path)
        rescue Errno::ENOENT
          nil
        end
      end
    end
  end
end
