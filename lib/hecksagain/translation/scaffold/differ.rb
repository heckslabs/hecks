module Hecksagain
  module Translation
    module Scaffold
      # Diff two eras' storage-shape projections into the edge's
      # declarations — confident rules by unique signature pairing,
      # everything ambiguous left unresolved for a human.
      module Differ
        # Diff two bluebook IRs into the edge's declarations.
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

        def projections(bluebook)
          Runtime::StorageShape.project(bluebook)["aggregates"].to_h { |shape| [shape["name"], shape] }
        end

        # A vanished aggregate whose full shape reappears under exactly one
        # new name was renamed. `retired` is only confident when NOTHING
        # remains it could plausibly have become — a vanished aggregate
        # beside an unmatched new one might be a rename-plus-reshape, and
        # writing `retired` there would be a guess that strands data.
        # Anything ambiguous stays unclaimed, and the coverage gate names
        # it until a human decides.
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

        # Every changed path in one aggregate, resolved into rules by
        # signature matching over the FULL path set — top-level names and
        # dotted members alike. Unique signature pair: a rename (both
        # top-level) or a move (any dotted end). Same path, same members,
        # new type name: a retype. Anything else: unresolved, carrying its
        # type-compatible candidates (an empty list is the arrow toward
        # compute, or drop).
        def attribute_rules(held_shape, current_shape)
          rules = []
          held_attrs = (held_shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }
          current_attrs = (current_shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }

          # retype pass: same attribute name, same member structure, the
          # TYPE's own name changed
          (held_attrs.keys & current_attrs.keys).each do |name|
            held = held_attrs[name]
            current = current_attrs[name]
            next if held == current
            next unless container?(held) && container?(current)
            next unless held["type"]["members"] == current["type"]["members"] && held["list"] == current["list"]

            rules << { kind: :retype, from: held["type"]["type"], to: current["type"]["type"] }
          end
          retyped = rules.filter_map { |rule| rule[:from] if rule[:kind] == :retype }

          vanished = vanished_paths(held_attrs, current_attrs, retyped)
          appeared = appeared_paths(held_attrs, current_attrs, retyped)

          vanished.each do |path, signature|
            matches = appeared.select { |_, candidate| candidate == signature }.keys
            taken = rules.filter_map { |rule| rule[:to] if %i[rename move].include?(rule[:kind]) }
            matches -= taken
            if matches.size == 1 && vanished.count { |_, other| other == signature } == 1
              target = matches.first
              kind = path.include?(".") || target.include?(".") ? :move : :rename
              rules << { kind: kind, from: path, to: target }
            else
              candidates = matches.empty? ? compatible_candidates(appeared, signature) : matches
              rules << { kind: :unresolved, from: path, candidates: candidates }
            end
          end
          rules
        end

        # Held paths that need explaining: whole attributes that vanished,
        # and members that vanished (or changed type) inside a kept
        # attribute — mirroring exactly what EraGuard will demand coverage
        # for.
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

        def compatible_candidates(appeared, signature)
          appeared.select { |_, candidate| scalar_of(candidate) == scalar_of(signature) }.keys
        end

        def scalar_of(signature) = signature.is_a?(Hash) ? signature["members"] : signature

        def members_of(attribute)
          return {} unless container?(attribute)

          attribute["type"]["members"].to_h { |member| [member["name"], member["type"]] }
        end

        def container?(attribute) = attribute["type"].is_a?(Hash)
      end
    end
  end
end
