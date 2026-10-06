require "digest"
require "fileutils"
require "json"

module Hecks
  module Doors
    # Remembers the help a launcher prints, so a repeat `hecks` need not read the domain again.
    #
    # The help is a pure function of the domain's declarations and of the gem that projects them,
    # and reading those is most of what a launcher costs. The answer is kept in a file named for a
    # digest of everything it depends on (the domain's declaration files, the gem's judging code and
    # doors, the hecks and Ruby versions, the environment overlay, the command line and the
    # program name),
    # so any edit to one of them is simply a different entry: nothing is ever stale, only unused.
    # Only an answer that ended well is kept, and any trouble with the cache itself is ignored
    # and the help is worked out as if it did not exist.
    #
    # `HECKS_NO_USAGE_CACHE=1` turns it off; `HECKS_CACHE_DIR` moves it.
    module UsageCache
      # The variable that turns the cache off when set to anything but empty or `0`.
      DISABLE_VARIABLE = "HECKS_NO_USAGE_CACHE".freeze
      # The variable that names the directory the cache lives in.
      DIRECTORY_VARIABLE = "HECKS_CACHE_DIR".freeze
      # The declaration files whose contents shape a help text.
      DECLARATIONS = "*.{bluebook,world,hecksagon,rb}".freeze
      # How long an unused entry stays before the next write sweeps it away.
      KEEP_SECONDS = 14 * 24 * 60 * 60

      module_function

      # Answers the cached help for this command line, or works it out with the block and
      # remembers it.
      #
      # @param runtime [#directory] what `Hecks.describe` answered; anything else bypasses the cache
      # @param argv [Array<String>] the command line
      # @param program [String] how the caller was invoked
      # @param audience [String] who the help is for, since the same line reads differently to each
      # @yield works the answer out, loading the domain
      # @yieldreturn [Array(String, Integer), nil] the text and status; nil if it runs a command
      # @return [Array(String, Integer), nil] the block's answer, or the remembered one
      def fetch(runtime, argv, program, audience: "")
        directory = runtime.respond_to?(:directory) ? runtime.directory : nil
        return yield unless directory && enabled?

        file = entry_path(directory, argv, program, audience)
        remembered = file && recall(file)
        return remembered if remembered

        answer = yield
        remember(file, answer) if worth_keeping?(file, answer)
        answer
      end

      # Whether an answer that ended well can be written to the entry's file.
      def worth_keeping?(file, answer)
        file && answer&.last&.zero?
      end

      # @return [Boolean] whether the cache is on
      def enabled?
        off = ENV[DISABLE_VARIABLE].to_s
        off.empty? || off == "0"
      end

      # @return [String] the directory entries live in
      def directory
        ENV[DIRECTORY_VARIABLE] || File.join(ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache"), "hecks")
      end

      # The file that holds the answer for this command line, named by what it depends on.
      #
      # @return [String, nil] nil when the digest cannot be taken
      def entry_path(domain, argv, program, audience = "")
        digest = Digest::SHA256.new
        key_parts(program, audience, argv).each { |part| digest << part.to_s << "\0" }
        fingerprint_code(domain, digest)
        File.join(directory, "usage-#{digest.hexdigest}.json")
      rescue SystemCallError
        nil
      end

      # @return [Array<String>] what the answer depends on besides the files: the gem and Ruby
      #   series, the environment overlay, the program and audience and the command line
      def key_parts(program, audience, argv)
        [Hecks::VERSION, Hecks::Bluebook::MetaValidator::VerdictCache.ruby_series,
         ENV["HECKS_ENVIRONMENT"].to_s, program, audience, argv.join("\0")]
      end

      # Feeds the digest every declaration file under `root`: its path below `root` and its bytes,
      # so a touch or a checkout elsewhere keeps the entry and an edit does not.
      def fingerprint(root, digest)
        Dir.glob(File.join(root, "**", DECLARATIONS)).each do |file|
          digest << file.delete_prefix(root) << "\0" << File.binread(file) << "\0"
        end
      end

      # Feeds the digest what shapes a help text: the domain's declarations, the judging trees of
      # the gem (the same set the verdict cache keys on) and the doors that render the text. An
      # edit to the gem's projections, deploy or release code cannot change a help line.
      def fingerprint_code(domain, digest)
        fingerprint(domain, digest)
        digest << Hecks::Bluebook::MetaValidator::VerdictCache.code_digest << "\0"
        fingerprint(__dir__, digest)
      end

      # Reads the remembered answer and marks the entry as used, so a sweep keeps what is read.
      #
      # @return [Array(String, Integer), nil] the remembered answer, or nil when none can be trusted
      def recall(file)
        record = JSON.parse(File.read(file))
        File.utime(nil, nil, file)
        [record.fetch("text"), record.fetch("status")]
      rescue SystemCallError, JSON::ParserError, KeyError
        nil
      end

      # Writes the answer beside its name and sweeps entries nobody has read for a while.
      def remember(file, answer)
        FileUtils.mkdir_p(File.dirname(file))
        scratch = "#{file}.#{Process.pid}"
        File.write(scratch, JSON.generate("text" => answer.first, "status" => answer.last))
        File.rename(scratch, file)
        sweep(File.dirname(file))
      rescue SystemCallError
        nil
      end

      # Removes the entries older than `KEEP_SECONDS`.
      def sweep(dir)
        cutoff = Time.now - KEEP_SECONDS
        Dir.glob(File.join(dir, "usage-*.json")).each do |entry|
          File.delete(entry) if File.mtime(entry) < cutoff
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
