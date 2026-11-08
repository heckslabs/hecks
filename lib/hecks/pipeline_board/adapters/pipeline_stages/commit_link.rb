# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # A landed commit as the run page links it: the commit on GitHub and its CI run.
      module CommitLink
        # @param sha [String] a commit
        # @param base [String, Hash] the repository's URL, or `{unknown:}` when it could not be read
        # @param runs [Array<Hash>, Hash] the board's CI rows (a 7-character `sha` and a `url`),
        #   or `{unknown:}`
        # @return [Hash] `sha` (shortened), `url` of the commit and `ci_url` of its CI run,
        #   each nil when unknown
        def self.of(sha, base, runs)
          found = runs.is_a?(Array) ? runs.find { |run| run[:sha] == sha[0, 7] } : nil
          { sha: sha[0, 9], url: base.is_a?(String) ? "#{base}/commit/#{sha}" : nil, ci_url: found && found[:url] }
        end
      end
    end
  end
end
