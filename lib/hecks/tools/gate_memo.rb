# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

module Hecks
  module Tools
    # The gate's memo of green runs, kept outside the checkout. A check whose inputs hash the same
    # as
    # the inputs of its last green run is reported as skipped, never as passed. The inputs of a
    # check
    # are the files it reads (the globs in `INPUTS`, hashed by content), together with the command
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

      # The files each check reads, as globs under the checkout. A glob is wide where the check
      # reads a whole tree: a change to any file a check could read reruns it, and a check is
      # skipped only when none of them moved. A check with no entry here is never skipped.
      SHAPE = %w[lib/**/*.rb lib/**/*.bluebook lib/**/*.hecksagon lib/**/*.world lib/**/*.json
                 lib/**/*.adapter translations/**/*].freeze
      STYLE = %w[lib/**/*.rb spec/**/*.rb docs/COMMENT_STYLE_GUIDE.md].freeze
      SPEC = %w[spec/spec_helper.rb spec/support/**/*.rb].freeze
      LIBRARY = %w[lib/**/*].freeze
      SOURCE = %w[lib/**/* spec/**/* examples/**/* exe/**/* bin/**/* docs/**/* rust/**/* .github/**/*
                  Gemfile Gemfile.lock *.gemspec .rubocop.yml .rubocop_todo.yml].freeze
      RUST = %w[rust/**/*.rs rust/**/Cargo.toml rust/**/Cargo.lock rust/rust-toolchain.toml
                rust-toolchain.toml].freeze
      MODEL = %w[lib/**/*.rb lib/**/*.bluebook lib/**/*.hecksagon lib/**/*.world examples/**/*].freeze

      INPUTS = {
        "shape_ledger"     => SHAPE,
        "comment_style"    => STYLE,
        "comment_blocks"   => STYLE + %w[examples/**/*.rb],
        "secret_output"    => LIBRARY + SPEC + %w[spec/secret_output_spec.rb],
        "everyday_names"   => LIBRARY + SPEC + %w[spec/everyday_names_spec.rb],
        "adapter_words"    => LIBRARY + SPEC + %w[spec/adapter_words_spec.rb],
        "rspec"            => SOURCE,
        "fuzzing"          => SOURCE,
        "query_agreement"  => SOURCE,
        "engine_agreement" => SOURCE,
        "model_check"      => MODEL,
        "doc_coverage"     => SOURCE,
        "codegen_drift"    => SOURCE,
        "rust_fmt"         => RUST
      }.freeze

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

      # @param root [String] the checkout
      # @param globs [Array<String>] globs under the checkout
      # @return [Array<String>] the regular files the globs name, relative to the checkout, sorted
      def files(root, globs)
        matched = globs.flat_map { |glob| Dir.glob(glob, base: root) }.uniq
        matched.reject { |rel| rel.split("/").intersect?(BUILD_DIRS) }
               .select { |rel| File.file?(File.join(root, rel)) }.sort
      end

      # @param root [String] the checkout
      # @param rel [String] a file relative to the checkout
      # @return [String] the sha256 of the file's content
      def sha(root, rel) = Digest::SHA256.file(File.join(root, rel)).hexdigest

      # @param root [String] the checkout
      # @param globs [Array<String>] the files to fingerprint
      # @return [String] one digest of each file's path and content, in path order
      def fingerprint(root, globs)
        rows = files(root, globs).map { |rel| "#{rel} #{sha(root, rel)}" }
        Digest::SHA256.hexdigest(rows.join("\n"))
      end

      # @param root [String] the checkout
      # @param check [Hash] a check: its `id` and its `run` words
      # @param env [Hash{String => String}] the environment the stage sets for the check
      # @return [String, nil] the digest of the check's command, environment and inputs; nil when
      # the
      #   check has no declared inputs, or one of them cannot be read, so it is never skipped
      def digest(root, check, env)
        globs = INPUTS[check["id"]]
        return nil unless globs

        words = ["run #{check["run"].join(" ")}", "env #{env.sort.map { |pair| pair.join("=") }.join(" ")}"]
        Digest::SHA256.hexdigest("#{words.join("\n")}\n#{fingerprint(root, globs)}")
      rescue SystemCallError
        nil
      end

      # @param entry [Hash, nil] the memo's entry for a check
      # @param inputs [String, nil] the check's digest now
      # @return [Boolean] whether the entry is a green run on exactly these inputs
      def reusable?(entry, inputs)
        !inputs.nil? && entry.is_a?(Hash) && entry["result"] == "green" && entry["inputs"] == inputs
      end

      # @return [Hash] a green entry for a check that ran on these inputs
      def green(inputs) = { "result" => "green", "at" => Time.now.utc.iso8601, "inputs" => inputs }
    end
  end
end
