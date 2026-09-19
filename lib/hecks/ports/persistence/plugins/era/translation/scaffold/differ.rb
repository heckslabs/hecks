require_relative "../../storage_shape"

module Hecks
  module Translation
    module Scaffold
      # Diff two eras' storage-shape projections into the edge's
      # declarations — confident rules by unique signature pairing,
      # everything ambiguous left unresolved for a human.
      module Differ
        # Diff two bluebook IRs into the edge's declarations.
        #
        # @param held_bluebook [Bluebook::Chapter] the era being translated from
        # @param current_bluebook [Bluebook::Chapter] the era being translated to
        # @return [Hash{Symbol => Object}] `:aggregates` (Array<Scaffold::ScaffoldedAggregate>,
        #   one per matched aggregate carrying a rename or a rule), `:retired` (Array<String>,
        #   vanished aggregate names with no successor), `:unclaimed` (Array<String>, vanished
        #   aggregate names left ambiguous)
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

        # Projects a bluebook's storage shape and indexes its aggregates by name.
        #
        # @param bluebook [Bluebook::Chapter] the bluebook to project
        # @return [Hash{String => Hash}] the bluebook's storage-shape aggregates (see
        #   `Runtime::StorageShape.project`), keyed by aggregate name
        def projections(bluebook)
          Runtime::StorageShape.project(bluebook)["aggregates"].to_h { |shape| [shape["name"], shape] }
        end

        # A vanished aggregate whose full shape reappears under exactly one
        # new name counts as a rename. `retired` is only confident when nothing
        # remains it could plausibly have become — a vanished aggregate
        # beside an unmatched new one might be a rename-plus-reshape, and
        # writing `retired` there would be a guess that strands data.
        # Anything ambiguous stays unclaimed, and the coverage gate names
        # it until a human decides.
        #
        # @param held_shapes [Hash{String => Hash}] the held era's aggregate shapes, keyed by
        #   name (see `projections`)
        # @param current_shapes [Hash{String => Hash}] the current era's aggregate shapes,
        #   keyed by name
        # @return [Hash{Symbol => Object}] `:pairs` (Hash{String => String, nil}, each current
        #   name to its matched held name, or nil when unmatched), `:retired` (Array<String>,
        #   vanished names with no successor), `:unclaimed` (Array<String>, vanished names
        #   left ambiguous)
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
        # signature matching over the full path set — top-level names and
        # dotted members alike. Unique signature pair: a rename (both
        # top-level) or a move (any dotted end). Same path, same members,
        # new type name: a retype. Anything else: unresolved, carrying its
        # type-compatible candidates (an empty list is the arrow toward
        # compute, or drop).
        #
        # @param held_shape [Hash{String => Object}] the held era's aggregate shape (see
        #   `projections`)
        # @param current_shape [Hash{String => Object}] the current era's aggregate shape
        # @return [Array<Hash{Symbol => Object}>] one rule Hash per changed path — `:kind`
        #   plus `:from`/`:to` for `:rename`/`:move`/`:retype`, or `:from`/`:candidates` for
        #   `:unresolved` (see `Renderer#render_rule`); `[]` when nothing changed
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

          # Mutates `rules` in place (not build-and-concat, like the two
          # passes above) because it must read its own earlier writes:
          # `taken`, below, is recomputed from `rules` at the top of every
          # iteration, so a target this same loop already claimed for an
          # earlier vanished path is excluded from a later one. Passing a
          # snapshot instead of the live array would let two vanished
          # paths both match the same appeared target.
          resolve_vanished_rules!(rules, vanished, appeared)
          rules
        end

        # retype pass: same attribute name, same member structure, the
        # type's own name changed
        #
        # @param held_attrs [Hash{String => Hash}] the held era's attributes, keyed by name
        # @param current_attrs [Hash{String => Hash}] the current era's attributes, keyed by
        #   name
        # @return [Array<Hash{Symbol => String}>] one `{kind: :retype, from:, to:}` rule per
        #   attribute whose members are unchanged but whose type name changed; `[]` when none
        #   match
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

        # Resolves each vanished path into a rename, move or unresolved rule, appended to
        # `rules` in place.
        #
        # @param rules [Array<Hash{Symbol => Object}>] the rule list to append to; also read
        #   for `:rename`/`:move` targets an earlier iteration already claimed
        # @param vanished [Hash{String => Object}] vanished paths to type signature (see
        #   `vanished_paths`)
        # @param appeared [Hash{String => Object}] appeared paths to type signature (see
        #   `appeared_paths`)
        # @return [void]
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

        # Held paths that need explaining: whole attributes that vanished,
        # and members that vanished (or changed type) inside a kept
        # attribute — mirroring exactly what EraGuard will demand coverage
        # for.
        #
        # @param held_attrs [Hash{String => Hash}] the held era's attributes, keyed by name
        # @param current_attrs [Hash{String => Hash}] the current era's attributes, keyed by
        #   name
        # @param retyped [Array<String>] type names already claimed by a `:retype` rule,
        #   excluded here
        # @return [Hash{String => Object}] each vanished or changed path, dotted for a member,
        #   valued by that path's type signature
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

        # Current paths that need explaining: whole attributes that appeared, and members
        # that appeared (or changed type) inside a kept attribute — the mirror of
        # `vanished_paths`.
        #
        # @param held_attrs [Hash{String => Hash}] the held era's attributes, keyed by name
        # @param current_attrs [Hash{String => Hash}] the current era's attributes, keyed by
        #   name
        # @param retyped [Array<String>] type names already claimed by a `:retype` rule,
        #   excluded here
        # @return [Hash{String => Object}] each appeared or changed path, dotted for a
        #   member, valued by that path's type signature
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

        # The one thing `attribute_rules` could not see before — the shape
        # projection already carries `"identity"` (`StorageShape
        # .project_aggregate`), it was simply never read here. An
        # unresolved placeholder, not a guess: `coverage_check.rb`'s own
        # `check_identity_unchanged!` is the real gate this only hints
        # toward, the same "tool proactively guides you" pattern the
        # generic unresolved message already gives unfed fields.
        #
        # @param held_shape [Hash{String => Object}] the held era's aggregate shape
        # @param current_shape [Hash{String => Object}] the current era's aggregate shape
        # @return [Hash{Symbol => Object}, nil] `{kind: :unresolved, from: :identity,
        #   candidates: []}` when the identity paths differ; nil when they match
        def identity_hint(held_shape, current_shape)
          return if held_shape["identity"] == current_shape["identity"]

          { kind: :unresolved, from: :identity, candidates: [] }
        end

        # Finds appeared paths type-compatible with a vanished path's own signature.
        #
        # @param appeared [Hash{String => Object}] appeared paths to type signature (see
        #   `appeared_paths`)
        # @param signature [Object] the vanished path's own type signature to match against
        # @return [Array<String>] appeared paths whose scalar signature (see `scalar_of`)
        #   matches `signature`'s
        def compatible_candidates(appeared, signature)
          appeared.select { |_, candidate| scalar_of(candidate) == scalar_of(signature) }.keys
        end

        # Reduces a type signature to the shape `compatible_candidates` compares by.
        #
        # @param signature [Object, Hash] a path's type signature
        # @return [Object] `signature["members"]` for a container Hash, else `signature`
        #   unchanged
        def scalar_of(signature) = signature.is_a?(Hash) ? signature["members"] : signature

        # Reads a container attribute's own members, keyed by name.
        #
        # @param attribute [Hash{String => Object}] one path's type signature
        # @return [Hash{String => Object}] each member's name to its type; `{}` when
        #   `attribute` is not a container
        def members_of(attribute)
          return {} unless container?(attribute)

          attribute["type"]["members"].to_h { |member| [member["name"], member["type"]] }
        end

        # Reports whether a type signature is a container (value object or entity), not a
        # scalar.
        #
        # @param attribute [Hash{String => Object}] one path's type signature
        # @return [Boolean] true if `attribute["type"]` is a Hash, false for a scalar
        def container?(attribute) = attribute["type"].is_a?(Hash)
      end
    end
  end
end
