# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Follows one file by byte offset: each read takes only the bytes written since the last one,
      # up to the last newline, so a line still being written waits for its end. The file is known
      # by its inode and its first bytes; one that was replaced, shortened or rewritten is read
      # anew. With `last:` a new read starts near the end of the file and holds that many lines,
      # so a long file is never read whole. It opens the file for reading only.
      class Tail
        # Bytes read at a time while looking back from the end of a file.
        BLOCK = 65_536
        # Bytes at the start of a file that say it is still the same file.
        HEAD = 64

        # What one read answers: whether the file was read anew, and the complete lines it took.
        Read = Struct.new(:anew, :lines)

        # @return [Integer] the bytes of lines read so far, which shows a read's bound
        attr_reader :bytes_read

        # @param last [Integer, nil] the lines a new read holds, taken from the end of the file;
        #   nil reads a new file from its start
        def initialize(last: nil)
          @last = last
          @offset = 0
          @bytes_read = 0
          @lock = Mutex.new
        end

        # @param path [String] where the followed file is now
        # @return [Read] `anew` when the file is not the one read before (its lines are then all
        #   that is held of it), and the lines appended since the last read
        def advance(path)
          @lock.synchronize { File.open(path, "rb") { |file| read(file) } }
        rescue SystemCallError, EOFError
          @identity = nil
          Read.new(true, [])
        end

        private

        def read(file)
          anew = replaced?(file)
          start(file) if anew
          lines = appended(file)
          Read.new(anew, anew ? newest(lines) : lines)
        end

        def replaced?(file)
          stat = file.stat
          @identity != [stat.dev, stat.ino] || stat.size < @offset || rewritten?(file)
        end

        # Whether the file's first bytes differ from the ones held; false until some are held.
        def rewritten?(file) = !@head.nil? && file.pread(@head.bytesize, 0) != @head

        def start(file)
          stat = file.stat
          @identity = [stat.dev, stat.ino]
          @head = nil
          @offset = @last ? near_end(file, stat.size) : 0
          @inside = @offset.positive?
        end

        # The offset of a block boundary with more than `last` newlines after it, or the start.
        def near_end(file, size)
          at = size
          found = 0
          while at.positive? && found <= @last
            step = [BLOCK, at].min
            at -= step
            found += take(file, step, at).count("\n")
          end
          at
        end

        # The lines of a new read: without the first when the read began inside the file, since
        # that one may be half a line, and no more than `last`.
        def newest(lines)
          lines.shift if @inside
          @last ? lines.last(@last) : lines
        end

        def appended(file)
          text = take(file, file.stat.size - @offset, @offset)
          cut = text.rindex("\n")
          return [] unless cut

          @offset += cut + 1
          @head ||= file.pread(HEAD, 0) if @offset >= HEAD
          text.byteslice(0, cut + 1).force_encoding(Encoding::UTF_8).lines
        end

        def take(file, length, offset)
          return +"" unless length.positive?

          @bytes_read += length
          file.pread(length, offset)
        end
      end
    end
  end
end
