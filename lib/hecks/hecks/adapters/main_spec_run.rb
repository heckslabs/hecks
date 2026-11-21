# frozen_string_literal: true

require "fileutils"
require "timeout"
require "tmpdir"
require_relative "shell"

module Hecks
  module Adapters
    # Runs the spec files a commit adds against `main`'s tree: a detached worktree of `main` gets
    # only those files from the commit, the launcher runs them, and the worktree is taken away
    # again after the files it was given are deleted. It reports what happened and judges nothing;
    # a run it cannot take, or that outlasts its time, is `unchecked`.
    class MainSpecRun
      # Seconds the run may take before it is reported unchecked.
      SECONDS = 150

      # RSpec's report that a spec file did not load.
      LOAD_ERROR = /errors? occurred (while loading|outside)/

      # RSpec's count line, `N examples, M failures`.
      SUMMARY = /(\d+) examples?, (\d+) failures?/

      # The line that names a failed example, `rspec ./spec/a_spec.rb:2 # description`.
      FAILED_EXAMPLE = /^rspec \S+ # (.+)$/

      # What a run reports when it could not be taken.
      UNCHECKED = { first_spec: "unchecked", first_example: "" }.freeze

      # @param shell [Shell] runs git and the launcher
      # @param seconds [Integer] how long the run may take
      def initialize(shell: Shell.new, seconds: SECONDS)
        @shell = shell
        @seconds = seconds
      end

      # @param checkout [String] the branch's checkout, whose repository holds `main`
      # @param sha [String] the commit that adds the specs
      # @param specs [Array<String>] the spec files it adds, relative to the repository
      # @return [Hash{Symbol => String}] `first_spec:` passed, failed, errored or unchecked, and
      #   `first_example:` the first example that failed, empty otherwise
      def call(checkout, sha, specs)
        Dir.mktmpdir("main-run") { |dir| Timeout.timeout(@seconds) { run(checkout, File.join(dir, "main"), sha, specs) } }
      rescue Timeout::Error, SystemCallError
        UNCHECKED
      end

      private

      def run(checkout, tree, sha, specs)
        return UNCHECKED unless @shell.capture("git", "worktree", "add", "--detach", tree, "main", chdir: checkout).ok?

        files = overlay(checkout, tree, sha, specs)
        read(@shell.capture(File.join(tree, "exe/hecks"), "test_suite_run.run_spec_files!", "files.value=#{specs.join(" ")}",
                            "isolation.value=shared", "--wait", chdir: tree))
      ensure
        retire(checkout, tree, files)
      end

      def overlay(checkout, tree, sha, specs)
        specs.map do |path|
          File.join(tree, path).tap do |file|
            FileUtils.mkdir_p(File.dirname(file))
            File.write(file, @shell.capture("git", "show", "#{sha}:#{path}", chdir: checkout).out)
          end
        end
      end

      # The files the run was given go first, so the tree is clean and a plain remove takes it.
      def retire(checkout, tree, files)
        Array(files).each { |file| FileUtils.rm_f(file) }
        @shell.capture("git", "worktree", "remove", tree, chdir: checkout)
      end

      def read(answer)
        text = answer.out
        return { first_spec: "errored", first_example: "" } if text.match?(LOAD_ERROR)

        counts = text.match(SUMMARY) or return UNCHECKED
        failed = counts[2].to_i.positive?
        { first_spec: failed ? "failed" : "passed", first_example: failed ? text[FAILED_EXAMPLE, 1].to_s : "" }
      end
    end
  end
end
