# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Tools
    module GateMemo
      # How the memo file is read and written: through a temp file renamed into place, changed
      # under a lock so a concurrent process's runs are kept, and never overwritten when it cannot
      # be read.
      module Storage
        # @param file [String] the memo's file
        # @return [Array(Hash, String)] the memo and nil; nil and why it could not be read. A
        #   missing file is an empty memo, not a problem.
        def read(file = path)
          return [{}, nil] unless File.exist?(file)

          memo = parse(file)
          memo.is_a?(Hash) ? [memo, nil] : [nil, "#{file} does not hold a JSON object"]
        rescue SystemCallError, JSON::ParserError => e
          [nil, "#{file}: #{e.message}"]
        end

        # Reads the file as JSON, trying again twice a moment later: a writer that does not rename
        # its file into place can be caught half way through it. A file that stays unreadable is
        # left as it is, never overwritten.
        #
        # @param file [String] the memo's file
        # @return [Object] the decoded JSON
        # @raise [JSON::ParserError] when the file still does not parse
        def parse(file, tries = 3)
          JSON.parse(File.read(file))
        rescue JSON::ParserError
          tries -= 1
          raise if tries.zero?

          sleep 0.05
          retry
        end

        # @param memo [Hash] the memo to keep
        # @param file [String] the memo's file
        # @return [String, nil] nil when it was written, else why it could not be
        def write(memo, file = path)
          FileUtils.mkdir_p(File.dirname(file))
          tmp = "#{file}.#{Process.pid}.tmp"
          File.write(tmp, "#{JSON.pretty_generate(memo)}\n")
          File.rename(tmp, file)
          nil
        rescue SystemCallError => e
          "#{file}: #{e.message}"
        end

        # Changes the memo as the file holds it now, under a lock, so the runs a concurrent process
        # recorded meanwhile are kept: the block sees the file as it is when the lock is had, not as
        # it was when the run began. The file is written through a temp file and renamed into place.
        #
        # @param file [String] the memo's file
        # @yieldparam memo [Hash] the memo to change in place
        # @return [String, nil] nil when it was written, else why it was not; an unreadable file is
        #   left as it is
        def update(file = path)
          FileUtils.mkdir_p(File.dirname(file))
          File.open("#{file}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            memo, problem = read(file)
            return problem if problem

            yield memo
            write(memo, file)
          end
        rescue SystemCallError => e
          "#{file}: #{e.message}"
        end
      end
    end
  end
end
