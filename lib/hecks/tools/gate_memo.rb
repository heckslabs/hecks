# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "time"
require "hecks/vocabulary"
require_relative "gate_memo/local_files"

module Hecks
  module Tools
    # The gate's memo of green runs, kept outside the checkout. A check whose inputs hash the same
    # as
    # the inputs of its last green run is reported as skipped, never as passed. The inputs of a
    # check
    # are the files it reads (the `inputs` of its `GateCheck` row, hashed by content), together with the command
    # and
    # the environment it runs under. A red result is never kept, so a red check runs again next
    # time.
    #
    # The rule itself is declared in the Check bluebook beside `GateRun`, in
    # lib/hecks/hecks/check/check.bluebook.
    module GateMemo
      # Build output is never an input: a Rust target directory is large, and its tool rebuilds
      # it (`target` and `node_modules`).
      BUILD_DIRS = %w[target node_modules .git].freeze

      # Where the memo is kept, unless `HECKS_GATE_MEMO` names another file.
      DEFAULT_PATH = File.join(Dir.home, ".claude", "hecks-dev", "gate_memo.json")

      # The files each check reads, as globs under the checkout, by check id: the `inputs` of the
      # `GateCheck` rows. A check whose row names none is never skipped.
      INPUTS = Hecks::Vocabulary.rows("GateCheck").each_with_object({}) do |row, found|
        globs = row["inputs"].to_s.split
        found[row["id"]] ||= globs.freeze unless globs.empty?
      end.freeze

      # The sha of each file this process has hashed, by path, modification time, size and inode, so
      # the checks of one run that read the same tree hash each file once.
      SHAS = {} # rubocop:disable Style/MutableConstant

      module_function

      # @return [String] the memo's file: `HECKS_GATE_MEMO` when set, else `DEFAULT_PATH`
      def path = ENV.fetch("HECKS_GATE_MEMO", DEFAULT_PATH)

      # @param file [String] the memo's file
      # @return [Array(Hash, String)] the memo and nil; nil and why it could not be read. A missing
      #   file is an empty memo, not a problem.
      def read(file = path)
        return [{}, nil] unless File.exist?(file)

        memo = JSON.parse(File.read(file))
        memo.is_a?(Hash) ? [memo, nil] : [nil, "#{file} does not hold a JSON object"]
      rescue SystemCallError, JSON::ParserError => e
        [nil, "#{file}: #{e.message}"]
      end

      # @param memo [Hash] the memo to keep
      # @param file [String] the memo's file
      # @return [String, nil] nil when it was written, else why it could not be
      def write(memo, file = path)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "#{JSON.pretty_generate(memo)}\n")
        nil
      rescue SystemCallError => e
        "#{file}: #{e.message}"
      end

      # The files a checkout owns: the ones git tracks and the ones it would add. A file git
      # ignores (a run's data directory, a build's output, a log) is never an input: a check's own
      # run rewrites those, so hashing them made the next run's inputs differ from the last.
      #
      # @param root [String] the checkout
      # @return [Array<String>, nil] its files relative to the checkout; nil when `root` is not a
      #   git checkout
      def owned(root)
        out, status = Open3.capture2("git", "-C", root, "ls-files", "-co", "--exclude-standard", "-z",
                                     err: File::NULL)
        status.success? ? out.split("\0") : nil
      rescue SystemCallError
        nil
      end

      # @param root [String] the checkout
      # @param globs [Array<String>] globs under the checkout
      # @return [Array<String>] the regular files the globs name, relative to the checkout, sorted;
      #   in a git checkout only the files it owns
      def files(root, globs)
        own = owned(root)
        matched = globs.flat_map { |glob| Dir.glob(glob, base: root) }.uniq
        matched &= own if own
        matched.reject { |rel| rel.split("/").intersect?(BUILD_DIRS) }
               .select { |rel| File.file?(File.join(root, rel)) }.sort
      end

      # @param root [String] the checkout
      # @param rel [String] a file relative to the checkout
      # @return [String] the sha256 of the file's content
      def sha(root, rel)
        path = File.join(root, rel)
        stat = File.stat(path)
        key = [path, stat.mtime.to_r, stat.size, stat.ino]
        SHAS.fetch(key) { SHAS[key] = Digest::SHA256.file(path).hexdigest }
      end

      # @param root [String] the checkout
      # @param globs [Array<String>] the files to fingerprint
      # @param local [Boolean] whether the checkout's local worlds are read too
      # @return [String] one digest of each file's path and content, in path order
      def fingerprint(root, globs, local: false)
        rows = files(root, globs).map { |rel| "#{rel} #{sha(root, rel)}" }
        rows += LocalFiles.files(root).map { |rel| "#{rel} #{sha(root, rel)}" } if local
        Digest::SHA256.hexdigest(rows.join("\n"))
      end

      # @param root [String] the checkout
      # @param check [Hash] a check: its `id` and its `run` words
      # @param env [Hash{String => String}] the environment the stage sets for the check
      # @return [String, nil] the digest of the check's command, environment and inputs; nil when
      # the
      #   check has no declared inputs, or one of them cannot be read, so it is never skipped
      def digest(root, check, env, tree = tree(root, check["id"]))
        return nil unless tree

        words = ["run #{check["run"].join(" ")}", "env #{env.sort.map { |pair| pair.join("=") }.join(" ")}"]
        Digest::SHA256.hexdigest("#{words.join("\n")}\n#{tree}")
      end

      # @param root [String] the checkout
      # @param id [String] a check's id
      # @return [String, nil] the digest of the files the check reads, whatever command runs it;
      #   nil when it has no declared inputs or one of them cannot be read
      def tree(root, id)
        globs = INPUTS[id]
        globs && fingerprint(root, globs, local: LocalFiles::BOOTING.include?(id))
      rescue SystemCallError
        nil
      end

      # @param entry [Hash, nil] the memo's entry for a check
      # @param inputs [String, nil] the check's digest now
      # @return [Boolean] whether the entry is a green run on exactly these inputs
      def reusable?(entry, inputs)
        !inputs.nil? && entry.is_a?(Hash) && entry["result"] == "green" && entry["inputs"] == inputs
      end

      # @param inputs [String] the digest of the command, the environment and the files
      # @param tree [String, nil] the digest of the files alone, which a standalone run of the same
      #   check compares with
      # @return [Hash] a green entry for a check that ran on these inputs
      def green(inputs, tree = nil)
        { "result" => "green", "at" => Time.now.utc.iso8601, "inputs" => inputs }.merge(tree ? { "tree" => tree } : {})
      end
    end
  end
end
