# frozen_string_literal: true

require "zlib"
require_relative "archive"

module Hecks
  module Runtime
    class EventTap
      # The move a full log makes: the live file becomes `<path>.1`, each numbered generation
      # shifts up one, and the generation past the last number goes to the {Archive}. A
      # generation the archive cannot take is dropped, so a full disk never stops the log.
      class Rotation
        # @param path [String] the live log's path
        # @param max_bytes [Integer] the size at which the log rotates
        # @param kept [Integer] the numbered generations kept beside the live log
        # @param archive [Archive] where the generation past the last number goes
        def initialize(path, max_bytes:, kept:, archive:)
          @path = path
          @max_bytes = max_bytes
          @kept = kept
          @archive = archive
        end

        # Rotates the log when it holds `max_bytes`; does nothing before that.
        #
        # @return [void]
        def call
          return unless File.exist?(@path) && File.size(@path) >= @max_bytes

          retire("#{@path}.#{@kept}")
          (@kept - 1).downto(1) { |number| shift(number) }
          File.rename(@path, "#{@path}.1")
        end

        private

        def retire(oldest)
          @archive.store(oldest) if File.file?(oldest)
        rescue SystemCallError, IOError, Zlib::Error
          nil
        end

        def shift(number)
          from = "#{@path}.#{number}"
          File.rename(from, "#{@path}.#{number + 1}") if File.exist?(from)
        end
      end
    end
  end
end
