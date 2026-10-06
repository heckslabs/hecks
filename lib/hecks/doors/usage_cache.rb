require "digest"
require "fileutils"
require "json"

module Hecks
  module Doors
    # Remembers the help a launcher prints, so a repeat `hecks` need not read the domain again.
    #
    # The help is a pure function of the domain's declarations and of the gem that projects them,
    # and reading those is most of what a launcher costs. The answer is kept in a file named for a
    # digest of everything it depends on (the domain's declaration files, the gem's own library,
    # the hecks and Ruby versions, the environment overlay, the command line and the program name),
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
      # @yield works the answer out, loading the domain
      # @yieldreturn [Array(String, Integer), nil] the text and status; nil if it runs a command
      # @return [Array(String, Integer), nil] the block's answer, or the remembered one
      def fetch(runtime, argv, program, &)
        domain = domain_of(runtime)
        return yield unless domain && enabled?

        file = entry_path(domain, argv, program)
        (file && recall(file)) || worked_out(file, &)
      end

      # The directory of the domain the runtime describes, or nil for a runtime that names none.
      def domain_of(runtime)
        runtime.directory if runtime.respond_to?(:directory)
      end

      # The block's answer, remembered when it ended well.
      def worked_out(file)
        answer = yield
        remember(file, answer) if file && answer&.last&.zero?
        answer
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
      def entry_path(domain, argv, program)
        digest = Digest::SHA256.new
        [Hecks::VERSION, RUBY_VERSION, ENV["HECKS_ENVIRONMENT"].to_s, program, argv.join("\0")].each do |part|
          digest << part.to_s << "\0"
        end
        [domain, library].each { |root| fingerprint(root, digest) }
        File.join(directory, "usage-#{digest.hexdigest}.json")
      rescue SystemCallError
        nil
      end

      # Feeds the digest every declaration file under `root`: its path, size and modification time.
      def fingerprint(root, digest)
        Dir.glob(File.join(root, "**", DECLARATIONS)).each do |file|
          stat = File.stat(file)
          digest << file << ":" << stat.size.to_s << ":" << stat.mtime.to_f.to_s << "\0"
        end
      end

      # @return [String] the gem's own library directory, which the frameworks load from
      def library
        File.expand_path("..", __dir__)
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
