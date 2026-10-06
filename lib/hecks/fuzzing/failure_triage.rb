require "digest"
require "fileutils"
require "json"

module Hecks
  module Fuzzing
    # Tells one fuzz finding from another and keeps the smallest repro of each.
    #
    # A finding's identity is its property (or exception class), its message with the minted
    # parts normalized away, and the shape of its shrunk steps (the verbs, in order). Two seeds
    # that break the same property the same way share an identity however their ids differ.
    module FailureTriage
      # Directory, under the checkout, where minimized repros are kept.
      REGRESSION_DIR = "spec/corpus/regressions".freeze

      module_function

      # @param property [String] the property name or exception class the finding opens with
      # @param message [String, nil] the finding's message
      # @param steps [Array<Hash>] the shrunk steps that reproduce it
      # @return [String] a stable twelve-character identity
      def signature(property, message, steps)
        shape = steps.map { |step| step["verb"] || step[:verb] }
        Digest::SHA256.hexdigest([property, normalize(message), shape].to_json)[0, 12]
      end

      # Strips the parts a run mints (ids, hex, numbers, quoted literals) so two runs of one
      # defect read the same.
      #
      # @param message [String, nil]
      # @return [String]
      def normalize(message)
        message.to_s
               .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "<uuid>")
               .gsub(/\b0x[0-9a-f]+\b|\b[0-9a-f]{16,}\b/i, "<hex>")
               .gsub(/(["']).*?\1/, "<str>")
               .gsub(/-?\d+(?:\.\d+)?/, "<n>")
               .squeeze(" ").strip
      end

      # Collapses findings to one per identity, keeping the smallest sequence of each.
      #
      # @param failures [Array<Hash>] findings carrying `:signature`, `:message` and `:steps`
      # @return [Array<Hash>] one finding per distinct identity, each with `:triage` (the
      #   identity) and `:duplicates` (how many findings it stands for)
      def dedupe(failures)
        failures.group_by { |failure| signature(failure[:signature], failure[:message], failure[:steps]) }
                .map do |identity, group|
          group.min_by { |failure| failure[:steps].length }.merge(triage: identity, duplicates: group.length)
        end
      end

      # Writes a minimized repro under `<root>/spec/corpus/regressions/<domain>/`, in the
      # `{name, note, steps}` shape `hecks run` replays. An existing file is never touched: the
      # identity is in the file name, so a finding already kept is left as it was.
      #
      # @param root [String] the checkout
      # @param domain_name [String] the domain's basename
      # @param finding [Hash] a `dedupe` result carrying `:triage`, `:steps`, `:seed`, `:message`
      # @return [String, nil] the path written, or nil when that finding was already kept
      def persist(root, domain_name, finding)
        dir = File.join(root, REGRESSION_DIR, domain_name)
        path = File.join(dir, "#{finding.fetch(:triage)}.json")
        return nil if File.exist?(path)

        FileUtils.mkdir_p(dir)
        File.write(path, JSON.pretty_generate(document(domain_name, finding)), mode: "wx")
        path
      rescue Errno::EEXIST
        nil
      end

      def document(domain_name, finding)
        { name:  "#{domain_name}-regression-#{finding.fetch(:triage)}",
          note:  "hecks fuzz found #{finding[:signature]} at seed #{finding[:seed]}: #{finding[:message]}",
          steps: finding.fetch(:steps) }
      end
    end
  end
end
