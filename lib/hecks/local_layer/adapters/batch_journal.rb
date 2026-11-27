# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # Reads from the edit journal which edits one batch holds. It only reads; the journal is
    # appended to by {EditJournal}.
    class BatchJournal
      # Raised when the journal cannot be read.
      class Unreadable < StandardError; end

      # @param value [Hash, String] a value object's hash or its bare value
      # @return [String] the value as text
      def self.plain(value) = value.is_a?(Hash) ? value.fetch(:value, "").to_s : value.to_s

      # @param path [String] the journal file
      def initialize(path)
        @path = path
      end

      # The latest journal record of each edit, kept when it is in this batch and not withdrawn.
      #
      # @param run [String] the batch's name
      # @param target [String] the bluebook the batch edits
      # @return [Array<Hash>] each with `:operation`, `:subject`, `:detail` as text
      # @raise [Unreadable] when the journal cannot be read
      def gathered(run, target)
        latest = File.foreach(@path).map { |line| JSON.parse(line, symbolize_names: true) }
                     .to_h { |held| [self.class.plain(held[:run]), held] }
        latest.values.select { |held| in_batch?(held, run, target) }.map { |held| fields(held) }
      rescue SystemCallError => e
        raise Unreadable, "the journal cannot be read: #{e.message}"
      end

      private

      def in_batch?(held, run, target)
        plain = self.class.method(:plain)
        plain.call(held[:batch]) == run && plain.call(held[:target]) == target && held[:status] != "withdrawn"
      end

      def fields(held) = held.slice(:operation, :subject, :detail).transform_values { |v| self.class.plain(v) }
    end
  end
end
