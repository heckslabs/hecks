require "json"
require "date"
require "fileutils"
require_relative "audit/approval_digest"
require_relative "../../../../../version"

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
      #
      # `host_version` is the Hecks release the rehearsal ran on, and the gate checks it: a
      # rehearsal counts only on a host whose release shares its `major.minor` (see
      # `host_compatible?`).
      REHEARSAL_KEYS = %w[snapshot host_version result at].freeze

      # How a `host_version` reads: `major.minor`, an optional patch, an optional pre-release or
      # build suffix. Only the first two numbers take part in the comparison.
      HOST_LINE = /\A(\d+)\.(\d+)(?:\.\d+)?(?:[-+][0-9A-Za-z.+-]+)?\z/

      # The release the running host reports: the Hecks release this code was built for. The Rust
      # host embeds the same string from `rust/host/HECKS_RELEASE`, and a spec fails when the two
      # drift.
      HOST_RELEASE = Hecks::VERSION

      # An ISO 8601 time: `2026-09-28T12:30:00Z`, with optional fraction and `+HH:MM` offset. The
      # host's approval.rs accepts the same shape.
      TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/

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
      # @return [Boolean] true when all of `REHEARSAL_KEYS` are non-empty Strings and `result` is
      #   `pass`
      def rehearsed?(rehearsal)
        return false unless rehearsal.is_a?(Hash)

        REHEARSAL_KEYS.all? { |key| named?(rehearsal[key]) } && rehearsal["result"] == "pass"
      end

      # The `major.minor` a version names.
      #
      # @param version [Object] a `host_version` as it reads from JSON
      # @return [Array<Integer>, nil] `[major, minor]`, or nil when it is not a version
      def release_line(version)
        match = HOST_LINE.match(version) if version.is_a?(String)
        match && [match[1].to_i, match[2].to_i]
      end

      # Whether a rehearsal ran on a host compatible with the running one.
      #
      # The rule is the smallest sound one: equal `major.minor`. A patch release does not change
      # what a mint does, so a rehearsal survives it; a minor or major release may, so a rehearsal
      # from an older host (or a newer one, which proves nothing about this one) does not.
      #
      # @param rehearsal [Hash] a rehearsal block, string-keyed
      # @param host_version [String] the running host's release
      # @return [Boolean] true when both versions parse and share `major.minor`
      def host_compatible?(rehearsal, host_version = HOST_RELEASE)
        line = release_line(rehearsal["host_version"])
        !line.nil? && line == release_line(host_version)
      end

      # The refusal for a rehearsal that ran on another host line; rust/host words it the same.
      #
      # @param rehearsal [Hash] a rehearsal block, string-keyed
      # @param host_version [String] the running host's release
      # @return [String] names both versions
      def host_refusal(rehearsal, host_version = HOST_RELEASE)
        line = release_line(host_version)&.join(".")
        "the rehearsal ran on Hecks #{rehearsal["host_version"]}, but this host is Hecks #{host_version}; " \
          "a rehearsal counts only on a host of the same major.minor (#{line}.x) — " \
          "re-run the rehearsal on this host and approve again"
      end

      # Whether a value is a String with something in it; a number or nil names nothing.
      #
      # @param value [Object] a field as it reads from JSON
      # @return [Boolean] true for a String that is not blank
      def named?(value) = value.is_a?(String) && !value.strip.empty?

      # Whether a value is an ISO 8601 time that exists on the calendar.
      #
      # @param value [Object] a field as it reads from JSON
      # @return [Boolean] true for a String of the `TIMESTAMP` shape with a real date and clock time
      def timestamp?(value)
        return false unless value.is_a?(String) && (match = TIMESTAMP.match(value))

        year, month, day, hour, minute, second = match.captures.map(&:to_i)
        Date.valid_date?(year, month, day) && hour < 24 && minute < 60 && second < 60
      end

      # Whether an approval names who approved it and when, the two things a reviewer signs.
      #
      # @param approval [Hash] the file, string-keyed as it reads from JSON
      # @return [Boolean] true when `approved_by` is a non-empty String and `approved_at` a time
      def attributed?(approval)
        named?(approval["approved_by"]) && timestamp?(approval["approved_at"])
      end

      # Builds the JSON document of one approval.
      #
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @param approved_by [String] who approved it, from their git identity
      # @param approved_at [String] when, as an ISO 8601 UTC time
      # @param rehearsal [Hash{String => String}, nil] the block; required for a compute or rekey
      # @return [Hash{String => Object}] `edge`, `edge_digest`, `approved_by`, `approved_at`, and
      #   `rehearsal` when one was given
      # @raise [ArgumentError] if `approved_by` is blank or `approved_at` is not a time, or if the
      #   edge needs a rehearsal and none that passed was given
      def build(edge:, approved_by:, approved_at:, rehearsal: nil)
        refuse_unattributed!(approved_by, approved_at)
        refuse_unrehearsed!(edge, rehearsal)

        document = { "edge" => edge_name(edge), "edge_digest" => edge_digest(edge),
                     "approved_by" => approved_by, "approved_at" => approved_at }
        document["rehearsal"] = rehearsal.slice(*REHEARSAL_KEYS) if rehearsal
        document
      end

      # Refuses an approval that does not say who approved it and when.
      #
      # @param approved_by [String] who approved it
      # @param approved_at [String] when, as an ISO 8601 UTC time
      # @return [void]
      # @raise [ArgumentError] if either is blank or malformed
      def refuse_unattributed!(approved_by, approved_at)
        return if attributed?("approved_by" => approved_by, "approved_at" => approved_at)

        raise ArgumentError, "an approval names who approved it (approved_by, your git identity) " \
                             "and when (approved_at, an ISO 8601 time)"
      end

      # Refuses the approval of a compute or rekey edge that carries no passing rehearsal.
      #
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @param rehearsal [Hash{String => String}, nil] the rehearsal block
      # @return [void]
      # @raise [ArgumentError] if the edge needs a rehearsal and none that passed was given
      def refuse_unrehearsed!(edge, rehearsal)
        return unless needs_rehearsal?(edge) && !rehearsed?(rehearsal)

        raise ArgumentError, "an edge with a compute or rekey rule is approved on a rehearsal that passed: " \
                             "name the snapshot, the host version, the result (pass) and when it ran"
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
      # @param host_version [String] the running host's release
      # @return [Hash{String => Object}, nil] an approval whose digest is the edge's, that names
      #   who approved it and when, and whose rehearsal passed on a compatible host when the edge
      #   needs one; nil when none applies
      def applicable(directory, edge, host_version: HOST_RELEASE)
        return unless directory

        digest = edge_digest(edge)
        read_all(directory).find do |approval|
          approval["edge_digest"] == digest && attributed?(approval) &&
            (!needs_rehearsal?(edge) ||
              (rehearsed?(approval["rehearsal"]) && host_compatible?(approval["rehearsal"], host_version)))
        end
      end

      # Why a committed approval that covers the edge was still not applied, when the only thing
      # wrong is the host it was rehearsed on.
      #
      # @param directory [String, nil] the domain's bluebook directory
      # @param edge [Bluebook::Translation] the parsed translation edge
      # @param host_version [String] the running host's release
      # @return [String, nil] `host_refusal`'s text, or nil when no such approval exists
      def host_mismatch(directory, edge, host_version: HOST_RELEASE)
        return unless directory && needs_rehearsal?(edge)

        digest = edge_digest(edge)
        stale = read_all(directory).find do |approval|
          approval["edge_digest"] == digest && stale_host?(approval, host_version)
        end
        host_refusal(stale["rehearsal"], host_version) if stale
      end

      # Whether an attributed approval's passing rehearsal ran on an incompatible host.
      #
      # @param approval [Hash{String => Object}] one parsed approval
      # @param host_version [String] the running host's release
      # @return [Boolean]
      def stale_host?(approval, host_version)
        attributed?(approval) && rehearsed?(approval["rehearsal"]) &&
          !host_compatible?(approval["rehearsal"], host_version)
      end
    end
  end
end
