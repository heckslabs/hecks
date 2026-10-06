module Hecks
  module CLI
    module ModelCheck
      # Examining booted domains: each one's findings against the allowlist, then the language's
      # own chapters, printed as the check goes. `ModelCheck` extends it.
      module Examination
        # @api private
        def examine_all(booted, options)
          known_domains = booted.flat_map { |_, registry| registry.bluebooks.keys + registry.hecksagons.keys }.to_set
          shared = { known_domains: known_domains, global_emitted_events: emitted_events_of(booted) }

          booted.reduce(true) { |all_ok, (name, registry)| domain_passes?(name, registry, options, **shared) && all_ok }
        end

        # @api private
        def emitted_events_of(booted)
          booted.flat_map do |_, registry|
            registry.bluebooks.values.flat_map { |chapter| Bluebook::ModelCheck.emitted_events(chapter) }
          end.to_set
        end

        def domain_passes?(name, registry, options, known_domains:, global_emitted_events:)
          puts "── #{name}"

          scope = { known_domains: known_domains, global_emitted_events: global_emitted_events,
                    rust_target: rust_target?(name, options.rust_dir), strict: options.strict, profile: options.profile }
          chapters = registry.bluebooks.values
          findings = chapters.flat_map do |chapter|
            Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name), **scope)
          end

          remaining = without_allowlisted(name, findings) or return false
          passes?(remaining, "   clean — #{chapters.size} chapter(s), no dead states, no unreachable protocol steps")
        end

        # Prints the allowlisted findings and answers the rest.
        #
        # @api private
        # @return [Array, nil] the findings the domain's allowlist does not cover, or nil when the
        #   allowlist holds entries that match nothing
        def without_allowlisted(name, findings)
          allowed = Bluebook::ModelCheck::ALLOWED_FINDINGS.fetch(name, [])
          matched, remaining = findings.partition { |f| allowed.include?([f.kind, f.subject]) }
          matched.each { |f| puts "   ALLOWLISTED  #{f}" }

          stale = allowed - matched.map { |f| [f.kind, f.subject] }
          return remaining if stale.empty?

          puts "   STALE ALLOWLIST ENTRIES (no longer found — remove them): #{stale.inspect}"
          nil
        end

        # Checked through `MetaValidator.grammar_registry`, the judged graph its
        # conformance specs use, because any one grammar file booted alone is a
        # fraction of the language.
        def examine_language(options)
          ok = true
          ["Bluebook", "World"].each do |name|
            chapter = Bluebook::MetaValidator.grammar_registry.bluebook(name)
            next unless chapter

            puts "── #{name} (the language itself)"
            findings = Bluebook::ModelCheck.call(chapter, strict: options.strict, profile: options.profile)
            ok = passes?(findings, "   clean — no dead states, no unreachable protocol steps") && ok
          end
          ok
        end

        # @api private
        def passes?(findings, clean_line)
          if findings.empty?
            puts clean_line
            return true
          end

          errors, warnings = findings.partition { |f| f.severity == :error }
          puts "   #{errors.size} error(s), #{warnings.size} warning(s)"
          findings.each { |f| puts "     #{f}" }
          errors.empty?
        end

        # The repository-only fuzzing tooling is loaded lazily, only when there is a
        # `rust/` to read.
        def rust_target?(name, rust_dir)
          return false unless rust_dir

          require_relative "../../fuzzing/target_capabilities"
          Fuzzing::TargetCapabilities.rust_feature?(name, rust_dir)
        end
      end
    end
  end
end
