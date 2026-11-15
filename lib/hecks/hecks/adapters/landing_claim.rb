# frozen_string_literal: true

require "digest"
require "fileutils"
require "hecks/cache_dir"
require_relative "console_capture"

module Hecks
  module Adapters
    # One landing of a checkout at a time. The gate and the shallow check a landing runs each hold
    # the checkout's claim while they run, and a second landing of that checkout that reaches
    # either while the first holds it is refused before it runs anything, naming the first.
    #
    # A claim is a kernel `flock` on a file named for the checkout's real path under the cache
    # directory, so a holder that dies, even killed, frees it at once. The file names the holder's
    # process, command and start for the refusal; it is emptied when the claim is let go.
    class LandingClaim
      # What a refusal begins with. It is not a gate's red, so no Work item is planned again for it.
      REFUSAL = "landing in flight"

      # @param base [#[]] the environment
      # @return [String] the directory the claims live in, under `HECKS_CACHE_DIR` when named
      def self.directory(base = ENV)
        named = base["HECKS_CACHE_DIR"].to_s
        named.empty? ? Hecks::CacheDir.path("landing-claims") : File.join(named, "landing-claims")
      end

      # @param dir [String] the directory the claims live in
      # @param words [Array<String>] the command line this process runs, for the holder's name
      # @param pid [Integer, nil] the holder's process; the process that takes the claim when nil
      def initialize(dir: self.class.directory, words: ARGV, pid: nil)
        @dir = dir
        @words = words
        @pid = pid
      end

      # Runs the block while holding the checkout's claim. A claim that cannot be opened is not
      # taken, and the block runs unclaimed.
      #
      # @param checkout [String] the checkout being landed
      # @return [Object] what the block returned
      # @raise [ConsoleCapture::Failure] when another landing holds the checkout's claim
      def hold(checkout)
        file = open_claim(checkout)
        return yield unless file

        refuse(file, checkout) unless file.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          name(file, holder)
          yield
        ensure
          name(file, "")
          file.close
        end
      end

      private

      def holder = "pid #{@pid || Process.pid} (#{@words.first(3).join(" ")}), since #{Time.now.utc.strftime("%FT%TZ")}"

      def open_claim(checkout)
        FileUtils.mkdir_p(@dir)
        File.new(File.join(@dir, "#{Digest::SHA256.hexdigest(real(checkout))[0, 16]}.lock"), File::CREAT | File::RDWR, 0o600)
      rescue SystemCallError
        nil
      end

      def real(checkout)
        File.realpath(checkout)
      rescue SystemCallError
        checkout
      end

      def refuse(file, checkout)
        held = file.read.strip
        file.close
        first = held.empty? ? "another landing" : held
        raise ConsoleCapture::Failure, "#{REFUSAL}: #{checkout} is being landed by #{first}; this second landing is refused"
      end

      def name(file, text)
        file.truncate(0)
        file.rewind
        file.write(text)
        file.flush
      end
    end
  end
end
