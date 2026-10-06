# frozen_string_literal: true

require "json"
require_relative "edge"

module Hecks
  module Projections
    module Site
      # Compares the CloudFront behaviours a site's edge generates with the ones a live
      # distribution has, and says every way they differ. It only reads: the live side is a
      # `get-distribution-config` answer, however it was obtained.
      #
      # A behaviour is identified by its path pattern (`(default)` for the default one) and judged
      # on its origin, allowed and cached methods, viewer protocol, compression and three policy
      # ids. The edge may name a policy by a CloudFormation intrinsic (`!Ref PageCachePolicy`) that
      # the live distribution holds as an id, so a reference is compared through the `refs` the
      # caller gives for it, and one with none is reported as unchecked. The behaviours a change is
      # about to add (`expect_new`) are reported as expected additions, not differences.
      class LiveEdge
        # The default behaviour's name, since it has no path pattern.
        DEFAULT = "(default)"

        # The fields a behaviour is compared on, besides its path.
        FIELDS = %i[origin methods cached protocol compress cache request response].freeze

        # What a comparison found.
        #
        # @!attribute [r] expected
        #   @return [Array<String>] a line per behaviour only the project has, that was expected
        # @!attribute [r] differences
        #   @return [Array<String>] a line per difference that was not expected
        # @!attribute [r] unchecked
        #   @return [Array<String>] the policy references no `refs` entry resolves
        # @!attribute [r] counts
        #   @return [Array<Integer>] the number of generated and of live behaviours, default aside
        Comparison = Struct.new(:expected, :differences, :unchecked, :counts, keyword_init: true) do
          # @return [Boolean] whether live is as generated, expected additions aside
          def clean? = differences.empty? && unchecked.empty?

          # @return [String] the report, one section per kind of finding
          def to_s
            lines = ["generated: #{counts[0]} behaviours + default; live: #{counts[1]} + default"]
            lines += section("expected additions (only in the project):", expected)
            lines += section("differences:", differences)
            lines += section("policy references with no refs entry (unchecked):", unchecked)
            lines << "the live distribution matches the project" if clean?
            lines.join("\n")
          end

          private

          def section(title, entries) = entries.empty? ? [] : [title, *entries.map { |entry| "  #{entry}" }]
        end

        # @param edge [Edge] the project's checked edge
        # @param live [Hash] a CloudFront distribution configuration, or an answer wrapping one in
        #   `DistributionConfig`
        # @param expect_new [Array<String>] path patterns the project may have and the live one not
        # @param refs [Hash{String => String}] a policy intrinsic to the id it stands for live
        def initialize(edge, live, expect_new: [], refs: {})
          @edge = edge
          @live = live.fetch("DistributionConfig", live)
          @expect_new = expect_new
          @refs = refs
        end

        # @return [Comparison] every way the project and the live distribution differ
        def call
          generated = generated_behaviours
          current = live_behaviours
          unchecked = unresolved(generated.values)
          generated = generated.transform_values { |entry| resolve(entry) }
          expected, differences = missing(generated, current)
          differences.concat(changed(generated, current), order(generated, current))
          Comparison.new(expected: expected, differences: differences, unchecked: unchecked,
                         counts: [generated.size - 1, current.size - 1])
        end

        # Reads a policy reference mapping written as `!Ref Name=id` words.
        #
        # @param text [String, nil] the words, separated by commas
        # @return [Hash{String => String}] each intrinsic to its id
        def self.refs_from(text)
          text.to_s.split(",").to_h { |pair| pair.strip.split("=", 2).map(&:strip) }
        end

        private

        def generated_behaviours
          list = [[DEFAULT, @edge.default_behaviour], *@edge.behaviours.map { |entry| [entry[:path], entry] }]
          list.to_h do |path, entry|
            [path, { path: path, origin: entry[:origin], methods: Array(entry[:methods]).sort, cached: %w[GET HEAD],
                     protocol: entry[:viewer_protocol], compress: entry[:compress] == true,
                     cache: policy_id(entry[:cache_policy]), request: policy_id(entry[:origin_request_policy]),
                     response: policy_id(entry[:response_headers_policy]) }]
          end
        end

        def policy_id(policy) = policy&.first

        def live_behaviours
          list = [[DEFAULT, @live.fetch("DefaultCacheBehavior")],
                  *Array(@live.dig("CacheBehaviors", "Items")).map { |entry| [entry.fetch("PathPattern"), entry] }]
          list.to_h do |path, entry|
            [path, { path: path, origin: entry.fetch("TargetOriginId"), methods: methods_of(entry, "Items"),
                     cached: cached_of(entry), protocol: entry.fetch("ViewerProtocolPolicy"),
                     compress: entry.fetch("Compress", false) == true, cache: entry["CachePolicyId"],
                     request: blank(entry["OriginRequestPolicyId"]), response: blank(entry["ResponseHeadersPolicyId"]) }]
          end
        end

        def methods_of(entry, key) = entry.fetch("AllowedMethods").fetch(key).sort

        def cached_of(entry) = entry.dig("AllowedMethods", "CachedMethods", "Items").sort

        def blank(value) = value.to_s.empty? ? nil : value

        def intrinsic?(value) = value.is_a?(String) && value.start_with?("!")

        def unresolved(entries)
          entries.flat_map { |entry| entry.values_at(:cache, :request, :response) }
                 .select { |value| intrinsic?(value) && !@refs.key?(value) }.uniq.sort
        end

        def resolve(entry) = entry.transform_values { |value| intrinsic?(value) ? @refs.fetch(value, value) : value }

        def missing(generated, current)
          expected = []
          differences = []
          generated.each do |path, entry|
            next if current.key?(path)

            detail = entry.except(:path).map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
            (@expect_new.include?(path) ? expected : differences) << "only in the project: #{path} #{detail}"
          end
          current.each_key { |path| differences << "only live: #{path}" unless generated.key?(path) }
          [expected, differences]
        end

        def changed(generated, current)
          generated.flat_map do |path, entry|
            next [] unless current.key?(path)

            FIELDS.filter_map do |field|
              next if entry[field] == current[path][field]

              "#{path} differs in #{field}: project=#{entry[field].inspect} live=#{current[path][field].inspect}"
            end
          end
        end

        def order(generated, current)
          mine = generated.keys.reject { |path| path == DEFAULT || !current.key?(path) }
          theirs = current.keys.reject { |path| path == DEFAULT || !generated.key?(path) }
          return [] if mine == theirs

          ["order differs among the behaviours both have:\n    project: #{mine.join(" ")}\n    live:    #{theirs.join(" ")}"]
        end
      end
    end
  end
end
