require "json"
require_relative "../corpus"

module Hecks
  module Fuzzing
    # The declared forms an aggregate can exhibit, and the pairs it puts together.
    #
    # Shared by the combination-coverage spec and `hecks quality_control target.judge_novelty` so
    # they cannot drift. The unit is one aggregate: forms on one head meet at dispatch, forms in one
    # chapter do not.
    module FormCensus
      # A given path crossing two references has at least this many segments.
      TWO_HOP_GIVEN_PATH_LENGTH = 3

      FORMS = {
        "composite_id"       => ->(a) { (a["identified_by"] || []).size >= 2 },
        "has_entity"         => ->(a) { entities(a).any? },
        "two_entities"       => ->(a) { entities(a).size >= 2 },
        "composite_piece"    => ->(a) { entities(a).any? { |piece| (piece["identified_by"] || []).size >= 2 } },
        "multi_emit"         => ->(a) { commands(a).any? { |verb| (verb["emits"] || []).size >= 2 } },
        "lifecycle"          => ->(a) { !a["lifecycle"].nil? },
        "piece_lifecycle"    => ->(a) { entities(a).any? { |piece| !piece["lifecycle"].nil? } },
        "has_query"          => ->(a) { queries(a).any? },
        "list_attr"          => ->(a) { attributes(a).any? { |held| held["list"] } },
        "reference_attr"     => ->(a) { attributes(a).any? { |held| reference?(held) } },
        "closed_set"         => ->(a) { (a["value_objects"] || []).any? { |shape| shape["closed_set"] } },
        "has_default"        => ->(a) { attributes(a).any? { |held| !held["default"].nil? } },
        "has_optional"       => ->(a) { commands(a).any? { |verb| (verb["attributes"] || []).any? { |held| held["optional"] } } },
        # Reference-hop forms, then `corrects` and `role`; entity commands count too.
        "corrects"           => ->(a) { every_command(a).any? { |verb| corrects?(verb) } },
        "role_gated"         => ->(a) { every_command(a).any? { |verb| !verb["role"].to_s.empty? } },
        "two_hop_given"      => ->(a) { two_hop_given?(a) },
        "multi_hop_where"    => ->(a) { multi_hop_where?(a) },
        "revalued_reference" => ->(a) { revalued_reference?(a) }
      }.freeze

      module_function

      def entities(aggregate)   = aggregate["entities"] || []

      def commands(aggregate)   = aggregate["commands"] || []

      # An aggregate's commands, its entities' included.
      def every_command(aggregate) = commands(aggregate) + entities(aggregate).flat_map { |piece| commands(piece) }

      def corrects?(verb) = (verb["mutations"] || []).any? { |change| change["op"].to_s == "corrects" }

      def attributes(aggregate) = aggregate["attributes"] || []

      def queries(aggregate)    = aggregate["queries"] || []

      def reference?(attribute) = attribute["type"].to_s.start_with?("Reference<")

      def two_hop_given?(aggregate)
        commands(aggregate).any? { |verb| (verb["givens"] || []).any? { |given| deep_lookup?(given["ast"]) } }
      end

      # A `where` whose field crosses two `/` hops, as in `member/sponsor/standing`.
      def multi_hop_where?(aggregate)
        queries(aggregate).any? { |query| (query["wheres"] || []).any? { |where| where["field"].to_s.count("/") >= 2 } }
      end

      # A command attribute reusing the name of a reference attribute under a non-reference type.
      def revalued_reference?(aggregate)
        references = attributes(aggregate).select { |held| reference?(held) }.to_set { |held| held["name"].to_s }
        commands(aggregate).any? do |verb|
          (verb["attributes"] || []).any? { |held| references.include?(held["name"].to_s) && !reference?(held) }
        end
      end

      def deep_lookup?(node)
        case node
        when Hash
          return true if node["op"] == "lookup" && Array(node["path"]).size >= TWO_HOP_GIVEN_PATH_LENGTH

          node.each_value.any? { |child| deep_lookup?(child) }
        when Array
          node.any? { |child| deep_lookup?(child) }
        else
          false
        end
      end

      def properties(aggregate)
        FORMS.transform_values { |form| form.call(aggregate) }
      end

      def pairs
        FORMS.keys.combination(2).map { |pair| pair_key(*pair) }
      end

      def pair_key(left, right) = [left, right].sort.join(" + ")

      def covered_pairs(held)
        held.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(name, shows), covered|
          shows.select { |_, present| present }.keys.combination(2).each do |left, right|
            covered[pair_key(left, right)] << name
          end
        end
      end

      def aggregates_in(chapter_ir)
        (chapter_ir["aggregates"] || []).map do |aggregate|
          ["#{chapter_ir["name"]}::#{aggregate["name"]}", properties(aggregate)]
        end
      end

      def bluebook_files(domain_path)
        Hecks::Corpus.bluebook_files(domain_path)
      end

      # The census over a domain on disk, booted lightweight (no `Hecks.boot`, no database).
      # Only the first-loaded chapter is measured.
      #
      # @raise [ArgumentError] if `domain_path` has no bluebook files
      def census(domain_path)
        root = File.expand_path("../../..", __dir__)
        files = bluebook_files(domain_path)
        raise ArgumentError, "#{domain_path} has no bluebook/*.bluebook (or *.bluebook) to measure" if files.nil?

        registry = Hecks::Runtime::Registry.new(root: File.expand_path(domain_path))
        Hecks.with_registry(registry) do
          Kernel.load(File.join(root, "lib/hecks/ports/persistence.port"))
          Kernel.load(File.join(root, "lib/hecks/ports/extraction.port"))
          Kernel.load(File.join(root, "lib/hecks/adapters/driven/memory.adapter"))
          Kernel.load(File.join(root, "lib/hecks/adapters/driven/prism.adapter"))
          files.each { |file| Kernel.load(file) }
        end

        chapter_name = registry.bluebooks.keys.first
        exported = JSON.parse(JSON.generate(Hecks::Projector::Exporter.call(registry).fetch(chapter_name)))
        aggregates_in(exported)
      end
    end
  end
end
