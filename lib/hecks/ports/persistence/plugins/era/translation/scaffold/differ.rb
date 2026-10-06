require_relative "../../storage_shape"
require_relative "path_diff"

module Hecks
  module Translation
    module Scaffold
      # Diffs two eras' storage shapes into the edge's declarations; rules are written only
      # for unique signature pairs, everything else is left unresolved.
      module Differ
        include PathDiff

        # Diffs two bluebook IRs into the edge's declarations.
        #
        # @param held_bluebook [Bluebook::Chapter] the era being translated from
        # @param current_bluebook [Bluebook::Chapter] the era being translated to
        # @return [Hash{Symbol => Object}] `:aggregates` (Array<Scaffold::ScaffoldedAggregate>),
        #   `:retired` (Array<String>, vanished names with no successor), `:unclaimed`
        #   (Array<String>, vanished names left ambiguous)
        def diff(held_bluebook, current_bluebook)
          held_shapes = projections(held_bluebook)
          current_shapes = projections(current_bluebook)

          matched = match_aggregates(held_shapes, current_shapes)
          aggregates = current_bluebook.aggregates.filter_map do |aggregate|
            scaffolded(aggregate, matched[:pairs], held_shapes, current_shapes)
          end

          { aggregates: aggregates, retired: matched[:retired], unclaimed: matched[:unclaimed] }
        end

        # One current aggregate's scaffolded rules, or nil when it is new or unchanged.
        def scaffolded(aggregate, pairs, held_shapes, current_shapes)
          held_name = pairs[aggregate.name]
          return unless held_name

          rules = attribute_rules(held_shapes[held_name], current_shapes[aggregate.name])
          was = held_name == aggregate.name ? nil : held_name
          return if rules.empty? && was.nil?

          ScaffoldedAggregate.new(name: aggregate.name, was: was, rules: rules)
        end

        # Projects a bluebook's storage shape, indexing its aggregates by name.
        def projections(bluebook)
          Runtime::StorageShape.project(bluebook)["aggregates"].to_h { |shape| [shape["name"], shape] }
        end

        # Pairs vanished aggregates with new ones whose full shape reappears under exactly one
        # name. A vanished aggregate is `retired` only when no unmatched new one remains, since
        # it could be a rename-plus-reshape and guessing would strand data.
        #
        # @param held_shapes [Hash{String => Hash}] held aggregate shapes, keyed by name
        # @param current_shapes [Hash{String => Hash}] current aggregate shapes, keyed by name
        # @return [Hash{Symbol => Object}] `:pairs` (current name to held name, or nil),
        #   `:retired` (Array<String>), `:unclaimed` (Array<String>)
        def match_aggregates(held_shapes, current_shapes)
          pairs = current_shapes.keys.to_h { |name| [name, held_shapes.key?(name) ? name : nil] }
          vanished = held_shapes.keys - current_shapes.keys
          appeared = current_shapes.keys.select { |name| pairs[name].nil? }
          unclaimed = claim_renamed!(vanished, appeared, pairs, held_shapes, current_shapes)

          retired = appeared.empty? ? unclaimed : []
          { pairs: pairs, retired: retired, unclaimed: retired.empty? ? unclaimed : [] }
        end

        # Pairs each vanished aggregate with the one appeared aggregate sharing its full shape,
        # mutating `pairs` and `appeared`; returns the vanished names left without a successor.
        def claim_renamed!(vanished, appeared, pairs, held_shapes, current_shapes)
          unclaimed = []
          vanished.each do |old_name|
            old_shape = held_shapes[old_name].merge("name" => nil)
            candidates = appeared.select { |name| current_shapes[name].merge("name" => nil) == old_shape }
            next unclaimed << old_name unless candidates.size == 1

            pairs[candidates.first] = old_name
            appeared.delete(candidates.first)
          end
          unclaimed
        end

        # Resolves every changed path in one aggregate into rules by signature matching:
        # a unique pair is a rename (both top-level) or a move (any dotted end), same members
        # under a new type name is a retype, anything else is unresolved with its candidates.
        #
        # @param held_shape [Hash{String => Object}] the held era's aggregate shape
        # @param current_shape [Hash{String => Object}] the current era's aggregate shape
        # @return [Array<Hash{Symbol => Object}>] one rule per changed path (see
        #   `Renderer#render_rule`); `[]` when nothing changed
        def attribute_rules(held_shape, current_shape)
          held_attrs = attributes_by_name(held_shape)
          current_attrs = attributes_by_name(current_shape)
          rules = [identity_hint(held_shape, current_shape)].compact
          rules.concat(retype_rules(held_attrs, current_attrs))
          retyped = rules.filter_map { |rule| rule[:from] if rule[:kind] == :retype }

          vanished = vanished_paths(held_attrs, current_attrs, retyped)
          appeared = appeared_paths(held_attrs, current_attrs, retyped)

          # Mutates `rules` in place: each iteration must see targets claimed by earlier ones,
          # or two vanished paths could match the same appeared target.
          resolve_vanished_rules!(rules, vanished, appeared)
          rules
        end

        # A shape's attributes keyed by name.
        def attributes_by_name(shape)
          (shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }
        end

        # Retype rules for attributes whose members are unchanged but whose type name changed.
        def retype_rules(held_attrs, current_attrs)
          (held_attrs.keys & current_attrs.keys).filter_map do |name|
            held = held_attrs[name]
            current = current_attrs[name]
            { kind: :retype, from: held["type"]["type"], to: current["type"]["type"] } if retyped?(held, current)
          end
        end

        # Whether two versions of an attribute differ only in the name of the same-shaped type.
        def retyped?(held, current)
          held != current && container?(held) && container?(current) &&
            held["type"]["members"] == current["type"]["members"] && held["list"] == current["list"]
        end

        # Resolves each vanished path into a rename, move or unresolved rule appended to `rules`.
        def resolve_vanished_rules!(rules, vanished, appeared)
          vanished.each do |path, signature|
            rules << rule_for(rules, path, signature, vanished, appeared)
          end
        end

        # The one rule a vanished path resolves to, given the targets earlier rules claimed.
        def rule_for(rules, path, signature, vanished, appeared)
          matches = appeared.select { |_, candidate| candidate == signature }.keys - claimed_targets(rules)
          if matches.size == 1 && vanished.one? { |_, other| other == signature }
            { kind: move_or_rename(path, matches.first), from: path, to: matches.first }
          else
            candidates = matches.empty? ? compatible_candidates(appeared, signature) : matches
            { kind: :unresolved, from: path, candidates: candidates }
          end
        end

        # A path crossing a value-object boundary on either end is a move; two bare names a rename.
        def move_or_rename(path, target) = path.include?(".") || target.include?(".") ? :move : :rename

        # The destinations the rename and move rules so far already took.
        def claimed_targets(rules)
          rules.filter_map { |rule| rule[:to] if %i[rename move].include?(rule[:kind]) }
        end

        # An unresolved placeholder when the identity paths differ; nil when they match.
        # It only hints: `check_identity_unchanged!` in `coverage_check.rb` is the real gate.
        def identity_hint(held_shape, current_shape)
          return if held_shape["identity"] == current_shape["identity"]

          { kind: :unresolved, from: :identity, candidates: [] }
        end
      end
    end
  end
end
