# frozen_string_literal: true

require "digest"
require "hecks/codemod"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "edit_applier"
require_relative "edit_journal"
require_relative "batch_journal"

module Hecks
  module Adapters
    # The `Previewing` port's adapter for `Batch`: answers `Diff` with the digest of the diff the
    # batch's gathered edits make against its target, and `Check` by recomputing that diff, holding
    # it to the digest shown, and loading the patched copy under the validators.
    #
    # It never writes the target. The diff text is kept beside the journal as `<run>.diff`, so the
    # diff a digest names can be read. What a batch holds is read from the journal alone.
    class BatchPreviewer
      # Raised when the diff cannot be made or the checks do not pass.
      class Refused < StandardError; end

      # What a run's name cannot hold when it names a file.
      UNSAFE = /[^\w.-]/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the journal file, `root:` where targets are resolved
      # @param root [String, nil] where targets are resolved when the settings name no root
      def initialize(aggregate: nil, settings: {}, root: nil)
        @journal = File.expand_path(settings[:path] || EditJournal::DEFAULT_PATH)
        @root = settings[:root] || root || Dir.pwd
        @held = BatchJournal.new(@journal)
      end

      # @param run [Hash, String] the batch's name
      # @param target [Hash, String] the bluebook the batch edits
      # @return [Hash{Symbol => String}] `text:` the target with the edits, `digest:` of the diff
      # @raise [Refused] when the target cannot be read or an edit does not apply
      def preview(run:, target:)
        text = unified(plain(run), plain(target))
        { text: patched(plain(run), plain(target)), digest: Digest::SHA256.hexdigest(text)[0, 12], diff: text }
      end

      # @param run [Hash, String] the batch's name
      # @param target [Hash, String] the bluebook the batch edits
      # @return [Hash{Symbol => Object}] the run and target with `diff:` the digest of the diff
      # @raise [Refused] when the target cannot be read or an edit does not apply
      def diff(run:, target:, **)
        shown = preview(run: run, target: target)
        File.write(diff_file(plain(run)), shown[:diff])
        { run: run, target: target, diff: { value: shown[:digest] } }
      end

      # @param diff [Hash, String] the digest of the diff shown
      # @return [Hash{Symbol => Object}] the run with `outcome:` `passed`
      # @raise [Refused] when the diff is not the one shown, or the patched copy does not load
      def check(run:, target:, diff:, **)
        shown = diff(run: run, target: target)[:diff]
        raise Refused, "the diff is not the one shown" unless shown[:value] == plain(diff)

        load_patched(plain(target), patched(plain(run), plain(target)))
        { run: run, outcome: { value: "passed" } }
      end

      private

      def plain(value) = BatchJournal.plain(value)

      def source(target)
        File.read(File.expand_path(target, @root))
      rescue SystemCallError => e
        raise Refused, "the target cannot be read: #{e.message}"
      end

      def patched(run, target)
        EditApplier.call(source(target), @held.gathered(run, target))
      rescue EditApplier::Unapplicable, BatchJournal::Unreadable => e
        raise Refused, e.message
      end

      def unified(run, target)
        Dir.mktmpdir do |dir|
          old = File.join(dir, "a")
          new = File.join(dir, "b")
          File.write(old, source(target))
          File.write(new, patched(run, target))
          Open3.capture2("diff", "-u", "--label", target, "--label", "#{target} (batch #{run})", old, new).first
        end
      end

      def diff_file(run)
        FileUtils.mkdir_p("#{@journal}.diffs")
        File.join("#{@journal}.diffs", "#{run.gsub(UNSAFE, "_")}.diff")
      end

      def load_patched(target, text)
        path = File.expand_path(target, @root)
        Hecks::Codemod::Shadow.put(path, text)
        Hecks::Codemod.load_bluebook(path)
      rescue StandardError => e
        raise Refused, "the target does not load with the edits: #{e.message}"
      ensure
        Hecks::Codemod::Shadow.drop(path)
      end
    end
  end
end
