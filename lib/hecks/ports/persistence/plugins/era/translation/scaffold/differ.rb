require_relative "../../storage_shape"

module Hecks
  module Translation
    module Scaffold
      # Diffs two eras' storage shapes into the edge's declarations; rules are written only
      # for unique signature pairs, everything else is left unresolved.
      module Differ
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
            held_name = matched[:pairs][aggregate.name]
            next unless held_name

            rules = attribute_rules(held_shapes[held_name], current_shapes[aggregate.name])
            was = held_name == aggregate.name ? nil : held_name
            next if rules.empty? && was.nil?

            ScaffoldedAggregate.new(name: aggregate.name, was: was, rules: rules)
          end

          { aggregates: aggregates, retired: matched[:retired], unclaimed: matched[:unclaimed] }
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
          pairs = {}
          current_shapes.each_key { |name| pairs[name] = held_shapes.key?(name) ? name : nil }

          vanished = held_shapes.keys - current_shapes.keys
          appeared = current_shapes.keys.select { |name| pairs[name].nil? }
          unclaimed = []
          vanished.each do |old_name|
            old_shape = held_shapes[old_name].merge("name" => nil)
            candidates = appeared.select { |name| current_shapes[name].merge("name" => nil) == old_shape }
            if candidates.size == 1
              pairs[candidates.first] = old_name
              appeared -= candidates
            else
              unclaimed << old_name
            end
          end

          retired = appeared.empty? ? unclaimed : []
          { pairs: pairs, retired: retired, unclaimed: retired.empty? ? unclaimed : [] }
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
          rules = []
          rules << identity_hint(held_shape, current_shape)
          rules.compact!
          held_attrs = (held_shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }
          current_attrs = (current_shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }

          rules.concat(retype_rules(held_attrs, current_attrs))
          retyped = rules.filter_map { |rule| rule[:from] if rule[:kind] == :retype }

          vanished = vanished_paths(held_attrs, current_attrs, retyped)
          appeared = appeared_paths(held_attrs, current_attrs, retyped)

          # Mutates `rules` in place: each iteration must see targets claimed by earlier ones,
          # or two vanished paths could match the same appeared target.
          resolve_vanished_rules!(rules, vanished, appeared)
          rules
        end

        # Retype rules for attributes whose members are unchanged but whose type name changed.
        def retype_rules(held_attrs, current_attrs)
          (held_attrs.keys & current_attrs.keys).filter_map do |name|
            held = held_attrs[name]
            current = current_attrs[name]
            next if held == current
            next unless container?(held) && container?(current)
            next unless held["type"]["members"] == current["type"]["members"] && held["list"] == current["list"]

            { kind: :retype, from: held["type"]["type"], to: current["type"]["type"] }
          end
        end

        # Resolves each vanished path into a rename, move or unresolved rule appended to `rules`.
        def resolve_vanished_rules!(rules, vanished, appeared)
          vanished.each do |path, signature|
            matches = appeared.select { |_, candidate| candidate == signature }.keys
            taken = rules.filter_map { |rule| rule[:to] if %i[rename move].include?(rule[:kind]) }
            matches -= taken
            if matches.size == 1 && vanished.one? { |_, other| other == signature }
              target = matches.first
              kind = path.include?(".") || target.include?(".") ? :move : :rename
              rules << { kind: kind, from: path, to: target }
            else
              candidates = matches.empty? ? compatible_candidates(appeared, signature) : matches
              rules << { kind: :unresolved, from: path, candidates: candidates }
            end
          end
        end

        # Held paths that need explaining: vanished attributes, and members that vanished or
        # changed type inside a kept attribute — the set EraGuard demands coverage for.
        # Returns each path (dotted for a member) valued by its type signature.
        def vanished_paths(held_attrs, current_attrs, retyped)
          paths = {}
          held_attrs.each do |name, held|
            next if retyped.include?(container?(held) ? held["type"]["type"] : nil)

            current = current_attrs[name]
            if current.nil?
              paths[name] = held["type"]
              next
            end
            next if held == current

            held_members = members_of(held)
            current_members = members_of(current)
            held_members.each do |member, signature|
              paths["#{name}.#{member}"] = signature if current_members[member] != signature
            end
          end
          paths
        end

        # Current paths that need explaining; the mirror of `vanished_paths`.
        def appeared_paths(held_attrs, current_attrs, retyped)
          paths = {}
          current_attrs.each do |name, current|
            next if retyped.include?(container?(current) ? current["type"]["type"] : nil)

            held = held_attrs[name]
            if held.nil?
              paths[name] = current["type"]
              next
            end
            next if held == current

            held_members = members_of(held)
            members_of(current).each do |member, signature|
              paths["#{name}.#{member}"] = signature if held_members[member] != signature
            end
          end
          paths
        end

        # An unresolved placeholder when the identity paths differ; nil when they match.
        # It only hints: `check_identity_unchanged!` in `coverage_check.rb` is the real gate.
        def identity_hint(held_shape, current_shape)
          return if held_shape["identity"] == current_shape["identity"]

          { kind: :unresolved, from: :identity, candidates: [] }
        end

        # Appeared paths type-compatible with a vanished path's signature.
        def compatible_candidates(appeared, signature)
          appeared.select { |_, candidate| scalar_of(candidate) == scalar_of(signature) }.keys
        end

        # Reduces a type signature to what `compatible_candidates` compares: members or the scalar.
        def scalar_of(signature) = signature.is_a?(Hash) ? signature["members"] : signature

        # A container attribute's members keyed by name; `{}` for a scalar.
        def members_of(attribute)
          return {} unless container?(attribute)

          attribute["type"]["members"].to_h { |member| [member["name"], member["type"]] }
        end

        # Whether the attribute's type is a container (value object or entity), not a scalar.
        def container?(attribute) = attribute["type"].is_a?(Hash)
      end
    end
  end
end
