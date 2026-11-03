# frozen_string_literal: true

require "json"
require "fileutils"

module Hecks
  module Adapters
    module PipelineBoard
      # The failed-job counts of completed runs, kept in memory and, when given a path, in a small
      # JSON file so a restarted server does not read them again. A run that has settled never
      # changes. The file is best-effort: one that cannot be read is a miss and one that cannot be
      # written is skipped, never an error.
      class SettledCounts
        KEPT = 200

        # @param path [String, nil] the JSON file, or nil to keep counts in memory only
        def initialize(path = nil)
          @path = path
          @lock = Mutex.new
          @counts = load
        end

        # @param id [Integer] the run id
        # @yieldreturn [Integer] the count, read when the run is not already known
        # @return [Integer] the run's failed-job count
        def fetch(id)
          key = id.to_s
          known = @lock.synchronize { @counts[key] }
          return known if known

          yield.tap { |count| remember(key, count) }
        end

        private

        def remember(key, count)
          @lock.synchronize do
            @counts[key] = count
            @counts.shift while @counts.size > KEPT
            save
          end
        end

        def load
          return {} unless @path

          found = JSON.parse(File.read(@path))
          found.is_a?(Hash) ? found.select { |_, count| count.is_a?(Integer) } : {}
        rescue SystemCallError, JSON::ParserError
          {}
        end

        def save
          return unless @path

          FileUtils.mkdir_p(File.dirname(@path))
          File.write("#{@path}.#{Process.pid}", JSON.generate(@counts))
          File.rename("#{@path}.#{Process.pid}", @path)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
