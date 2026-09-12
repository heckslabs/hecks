require "json"

module Hecks
  module Fuzzing
    # WHAT AN AGGREGATE CAN EXHIBIT, AND WHICH PAIRS IT PUTS TOGETHER.
    #
    # Extracted from `spec/combination_coverage_spec.rb`'s own pairwise
    # table so it has exactly two consumers that can never drift: that
    # spec (the golden corpus, held to every pair) and `bin/qa_domain_
    # novelty` (a CANDIDATE stress domain, measured against every path
    # the QA ledger already sweeps — see that script's own header for why
    # a new domain has to name the pair no existing target meets before
    # it earns a place in the rotation).
    #
    # THE UNIT IS ONE AGGREGATE. Two forms in the same chapter but
    # different heads never meet at dispatch; two forms on one head do
    # — that spec's own header has the four defects that argument came
    # from. Each entry below is a form the language declares and a
    # runtime has to handle, chosen because it has produced a defect or
    # sits one step from one; adding one here is how a new form joins
    # BOTH gates at once, and it will name its own uncovered pairs on the
    # first run of each.
    #
    # ONE FLAT TABLE, ON PURPOSE — each entry is an independent boolean
    # check against the same string-keyed aggregate IR hash (the shape
    # `spec/golden/ir/*.json` carries and `Projector::Exporter.call`
    # round-trips to through JSON), laid out so every declared form can
    # be read, and added to, at a glance.
    module FormCensus
      # A `given`'s own lookup path crossing at least two references —
      # `member.sponsor.standing`, `source.customer.status`: the
      # `CommandRules::References#dereference` recursion, walked only
      # on a fresh command argument (S12, ADR 0025) and hydrated one
      # repository lookup per hop.
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
        # THE REFERENCE-HOP FAMILY (ANGLE-2, qa/bluebook ledger) — the
        # forms `qa/stress_domains/referral_chain` exists for, absent
        # from the census until that domain named them. Each is one
        # step from a catalogued gap: `two_hop_given` is `dereference`'s
        # own recursion (`DEREFERENCE_DEPTH`); `multi_hop_where` is a
        # `/`-chain `HopPath` walks for real and `rust/project/queries.
        # rb` structurally refuses (D2 of the equivalence-gap plan);
        # `revalued_reference` is ADR 0037 Finding 5's exact trigger — a
        # command redeclaring the aggregate's own reference field under
        # a non-reference type, so only `resolve_state_references` (never
        # ported) can catch a dangling id.
        "two_hop_given"      => ->(a) { two_hop_given?(a) },
        "multi_hop_where"    => ->(a) { multi_hop_where?(a) },
        "revalued_reference" => ->(a) { revalued_reference?(a) }
      }.freeze

      module_function

      def entities(aggregate)   = aggregate["entities"] || []
      def commands(aggregate)   = aggregate["commands"] || []
      def attributes(aggregate) = aggregate["attributes"] || []
      def queries(aggregate)    = aggregate["queries"] || []
      def reference?(attribute) = attribute["type"].to_s.start_with?("Reference<")

      def two_hop_given?(aggregate)
        commands(aggregate).any? { |verb| (verb["givens"] || []).any? { |given| deep_lookup?(given["ast"]) } }
      end

      # A `where` whose field crosses two `/` — `member/sponsor/standing`.
      def multi_hop_where?(aggregate)
        queries(aggregate).any? { |query| (query["wheres"] || []).any? { |where| where["field"].to_s.count("/") >= 2 } }
      end

      # A command attribute sharing a name with one of the aggregate's
      # own reference-typed attributes while carrying a DIFFERENT, non-
      # reference type — `attribute :member, Handle` against
      # `reference_to Member`.
      def revalued_reference?(aggregate)
        references = attributes(aggregate).select { |held| reference?(held) }.to_set { |held| held["name"].to_s }
        commands(aggregate).any? do |verb|
          (verb["attributes"] || []).any? { |held| references.include?(held["name"].to_s) && !reference?(held) }
        end
      end

      # Walks a given's own exported AST for any `lookup` whose path is
      # long enough to have crossed two references.
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

      # Every form, answered for one aggregate — the table above, applied.
      def properties(aggregate)
        FORMS.transform_values { |form| form.call(aggregate) }
      end

      # Every unordered pair of forms, each rendered "left + right" in
      # alphabetical order — the key both gates' excuse tables use.
      def pairs
        FORMS.keys.combination(2).map { |pair| pair_key(*pair) }
      end

      def pair_key(left, right) = [left, right].sort.join(" + ")

      # `held` is `[[aggregate_name, properties], ...]`. Answers which
      # pairs are met on ONE aggregate, and by which — a Hash from pair
      # key to the names carrying it, so a caller can say who.
      def covered_pairs(held)
        held.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(name, shows), covered|
          shows.select { |_, present| present }.keys.combination(2).each do |left, right|
            covered[pair_key(left, right)] << name
          end
        end
      end

      # `[[\"Chapter::Aggregate\", properties], ...]` for every aggregate
      # a string-keyed chapter IR declares — the same walk the golden
      # spec makes over `spec/golden/ir/*.json`.
      def aggregates_in(chapter_ir)
        (chapter_ir["aggregates"] || []).map do |aggregate|
          ["#{chapter_ir['name']}::#{aggregate['name']}", properties(aggregate)]
        end
      end

      # WHERE A DOMAIN PATH KEEPS ITS BLUEBOOKS — `<domain>/bluebook/*.
      # bluebook` (every example and stress domain), or the directory
      # itself (`qa/bluebook`, the ledger's own `Target.path`): the same
      # two shapes `bin/model_check`'s `bluebook_in` reads. `nil` when
      # neither holds a bluebook.
      def bluebook_files(domain_path)
        [File.join(domain_path, "bluebook"), domain_path].each do |dir|
          files = Dir[File.join(dir, "*.bluebook")]
          return files unless files.empty?
        end
        nil
      end

      # THE SAME CENSUS OVER A DOMAIN ON DISK, booted the lightweight
      # way `bin/model_check` and `Hecks::Codemod.load_bluebook` already
      # do (ports and the two in-process adapters, no `Hecks.boot`, no
      # live database, no `.hecksagon`: the census reads declared SHAPE,
      # and a framework chapter a `.hecksagon` would attach is not this
      # domain's own). Only the domain's own chapter is measured — the
      # first bluebook loaded, the same "target chapter is always first"
      # fact `bin/project_rust` relies on.
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
