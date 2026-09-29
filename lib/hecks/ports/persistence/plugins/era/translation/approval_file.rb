require "json"
require "fileutils"
require_relative "audit/approval_digest"

module Hecks
  module Translation
    # The committed form of an edge's approval: `translations/<edge>.approval`, a JSON file beside
    # the edge that a reviewer sees in the same diff.
    #
    # It binds to the edge's content digest and not to the journal's tip, so a production journal
    # that keeps writing between the commit and the deploy does not void it. An edge with a compute
    # or rekey rule also carries the rehearsal a person ran against real data, since the audit's
    # samples are that edge's only other verification.
    module ApprovalFile
      EXTENSION = ".approval".freeze

      # The keys of a rehearsal block; every one is required when the block is required.
      REHEARSAL_KEYS = %w[snapshot host_version result at].freeze

      extend Audit::ApprovalDigest

      module_function

      # Names an edge by the labels it joins; labels are hex, so the dash cannot be part of one.
      #
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @return [String] `<from>-<to>`
      def edge_name(edge) = "#{edge.from}-#{edge.to}"

      # Where an edge's approval lives.
      #
      # @param directory [String] the domain's bluebook directory
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @return [String] `<directory>/translations/<edge>.approval`
      def path_for(directory, edge) = File.join(directory, "translations", "#{edge_name(edge)}#{EXTENSION}")

      # Whether the edge carries a rule whose only verification is a human's review of samples.
      #
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @return [Boolean] true when any aggregate declares a compute or a rekey
      def needs_rehearsal?(edge)
        edge.aggregates.any? { |declared| !declared.computes.empty? || !declared.rekeys.empty? }
      end

      # Whether a rehearsal block records a run that passed, with every field named.
      #
      # @param rehearsal [Hash, nil] the block, string-keyed as it reads from JSON
      # @return [Boolean] true when all of `REHEARSAL_KEYS` are non-empty and `result` is `pass`
      def rehearsed?(rehearsal)
        return false unless rehearsal.is_a?(Hash)

        REHEARSAL_KEYS.all? { |key| !rehearsal[key].to_s.strip.empty? } && rehearsal["result"] == "pass"
      end

      # Builds the JSON document of one approval.
      #
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @param approved_by [String] who approved it, from their git identity
      # @param approved_at [String] when, as an ISO 8601 UTC time
      # @param rehearsal [Hash{String => String}, nil] the block; required for a compute or rekey
      # @return [Hash{String => Object}] `edge`, `edge_digest`, `approved_by`, `approved_at`, and
      #   `rehearsal` when one was given
      # @raise [ArgumentError] if the edge needs a rehearsal and none that passed was given
      def build(edge:, approved_by:, approved_at:, rehearsal: nil)
        if needs_rehearsal?(edge) && !rehearsed?(rehearsal)
          raise ArgumentError, "an edge with a compute or rekey rule is approved on a rehearsal that passed: " \
                               "name the snapshot, the host version, the result (pass) and when it ran"
        end

        document = { "edge" => edge_name(edge), "edge_digest" => edge_digest(edge),
                     "approved_by" => approved_by, "approved_at" => approved_at }
        document["rehearsal"] = rehearsal.slice(*REHEARSAL_KEYS) if rehearsal
        document
      end

      # Writes an edge's approval file, replacing an earlier approval of the same edge.
      #
      # @param directory [String] the domain's bluebook directory
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @param document [Hash{String => Object}] what `build` answered
      # @return [String] the path written
      def write!(directory, edge, document)
        path = path_for(directory, edge)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(document)}\n")
        path
      end

      # Reads every committed approval of a domain.
      #
      # @param directory [String] the domain's bluebook directory
      # @return [Array<Hash{String => Object}>] each parsed file; one that is not JSON is skipped,
      #   since a file that cannot be read approves nothing
      def read_all(directory)
        Dir[File.join(directory, "translations", "*#{EXTENSION}")].filter_map do |path|
          parsed = JSON.parse(File.read(path))
          parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      end

      # The committed approval that lets an edge mint, if there is one.
      #
      # @param directory [String, nil] the domain's bluebook directory
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @return [Hash{String => Object}, nil] an approval whose digest is the edge's and whose
      #   rehearsal passed when the edge needs one; nil when none applies
      def applicable(directory, edge)
        return unless directory

        digest = edge_digest(edge)
        read_all(directory).find do |approval|
          approval["edge_digest"] == digest && (!needs_rehearsal?(edge) || rehearsed?(approval["rehearsal"]))
        end
      end
    end
  end
end
