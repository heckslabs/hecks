# frozen_string_literal: true

require "tempfile"
require_relative "batch_previewer"

module Hecks
  module Adapters
    # The `Applying` port's adapter for `Batch`: answers `Write` by recomputing the diff the batch's
    # gathered edits make, holding it to the digest shown, and replacing the target with the patched
    # text through a temp file and a rename, so the target is whole or untouched.
    class BatchApplier
      # Raised when the diff is not the one shown or the target cannot be written.
      class Refused < StandardError; end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the journal file, `root:` where targets are resolved
      # @param root [String, nil] where targets are resolved when the settings name no root
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = settings[:root] || root || Dir.pwd
        @previewer = BatchPreviewer.new(settings: settings, root: @root)
      end

      # @param run [Hash, String] the batch's name
      # @param target [Hash, String] the bluebook the batch edits
      # @param diff [Hash, String] the digest of the diff shown
      # @return [Hash{Symbol => Object}] the run and target
      # @raise [Refused] when the diff is not the one shown, or the target cannot be written
      def write(run:, target:, diff:, **)
        shown = @previewer.preview(run: run, target: target)
        raise Refused, "the diff is not the one shown" unless shown[:digest] == BatchJournal.plain(diff)

        replace(File.expand_path(BatchJournal.plain(target), @root), shown[:text])
        { run: run, target: target }
      rescue BatchPreviewer::Refused => e
        raise Refused, e.message
      end

      private

      def replace(path, text)
        Tempfile.create([File.basename(path), ".tmp"], File.dirname(path)) do |file|
          file.write(text)
          file.close
          File.rename(file.path, path)
        end
      rescue SystemCallError => e
        raise Refused, "the target cannot be written: #{e.message}"
      end
    end
  end
end
