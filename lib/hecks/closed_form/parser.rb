require "digest"
require "fileutils"
require "open3"
require_relative "../cache_dir"

module Hecks
  module ClosedForm
    # Finds the `hecks-parse` binary the closed form runs, building it from the parser's sources
    # when there is none for them yet.
    #
    # The gem carries the parser's sources (`rust/parser/`), so the binary is built for exactly
    # those sources, once, with cargo, and found by their digest afterwards: beside the crate in a
    # checkout, where a cache that is emptied cannot take it, and under the cache directory in an
    # installed gem, which is read-only. `HECKS_PARSE_BIN` names a binary to use instead.
    module Parser
      # The parser crate's root, inside the checkout or the installed gem.
      CRATE = File.expand_path("../../../rust/parser", __dir__).freeze

      # Raised when no binary is named and cargo cannot build one; the message says how to get one.
      class Missing < StandardError; end

      module_function

      # @return [String] the binary's path: `HECKS_PARSE_BIN`, or the build for these sources
      # @raise [Missing] when neither can be had
      def binary
        return @binary if @binary && File.executable?(@binary)

        @binary = named || built
      end

      # @return [String] what a cached admitted text is keyed on: the named binary's path, size and
      #   time, or the digest of the sources the build was made from
      def identity
        @identity ||= begin
          path = named
          path ? [path, File.size(path), File.mtime(path).to_i].join(":") : sources_digest
        end
      end

      # @return [String, nil] the binary `HECKS_PARSE_BIN` names, when it is an executable file
      # @raise [Missing] when it names something else
      def named
        path = ENV.fetch("HECKS_PARSE_BIN", nil)
        return if path.nil? || path.empty?
        return path if File.file?(path) && File.executable?(path)

        raise Missing, "HECKS_PARSE_BIN names #{path}, which is not an executable file"
      end

      # @return [String] the build of the parser for its current sources, made once
      # @raise [Missing] when there is no build and cargo cannot make one
      def built
        target = File.join(builds, sources_digest[0, 16])
        executable = File.join(target, "release", "hecks-parse")
        build(target) unless File.executable?(executable)
        executable
      end

      # @return [String] where builds live: the crate's own `target/` when the crate is writable
      def builds
        crate_target = File.join(CRATE, "target", "closed-form")
        File.writable?(CRATE) ? crate_target : CacheDir.path("hecks-parse")
      end

      # @return [String] the digest of everything the build reads
      def sources_digest
        @sources_digest ||= begin
          files = Dir.glob(File.join(CRATE, "{Cargo.toml,Cargo.lock,src/**/*.rs}"))
          Digest::SHA256.hexdigest(files.map { |file| "#{file.delete_prefix(CRATE)}\0#{File.read(file)}" }.join("\0"))
        end
      end

      # Builds the parser into `target`; cargo's lock on the directory makes a parallel build wait.
      def build(target)
        FileUtils.mkdir_p(target)
        warn "hecks: building hecks-parse for the closed form (once for these parser sources)"
        _out, err, status = Open3.capture3("cargo", "build", "--release", "--quiet", "--manifest-path",
                                           File.join(CRATE, "Cargo.toml"), "--target-dir", target)
        raise Missing, "cargo could not build hecks-parse: #{err.strip}" unless status.success?
      rescue Errno::ENOENT
        raise Missing, "hecks-parse is needed to read declaration files (.bluebook, .hecksagon, " \
                       ".world, .contextmap): install Rust (cargo) so the gem can build it, " \
                       "or set HECKS_PARSE_BIN"
      end
      private_class_method :build
    end
  end
end
