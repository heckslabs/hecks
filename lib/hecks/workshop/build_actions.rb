module Hecks
  class Workshop
    # Hecks::Workshop::BuildActions
    #
    # Session methods for validating, previewing, building, and saving
    # the domain being constructed. Part of the Session layer -- mixed
    # into Session to keep build-phase logic separate from play-mode.
    #
    # Provides the core workflow for going from an in-memory domain definition
    # to a validated, generated Ruby gem on disk. Also supports serializing the
    # domain back to DSL source code for persistence and reloading.
    #
    #   workshop.validate
    #   workshop.preview("Pizza")
    #   workshop.build(version: "1.0.0")
    #   workshop.save("Bluebook")
    #
    module BuildActions
      # Validate the current domain definition.
      #
      # Builds the domain from current aggregate builders and runs the
      # Hecks validator. Prints a success summary (aggregate/command/event
      # counts) or lists validation errors.
      #
      # @return [Boolean] true if the domain is valid, false otherwise
      def validate
        domain = to_domain
        valid, errors = Hecks.validate(domain)

        if valid
          puts "Valid (#{domain.aggregates.size} aggregates, #{total_commands(domain)} commands, #{total_events(domain)} events)"
        else
          puts "Invalid:"
          errors.each { |e| puts "  - #{e}" }
        end

        valid
      end

      # Preview generated Ruby code for one or all aggregates.
      #
      # When given an aggregate name, prints only that aggregate's generated
      # code. When called without arguments, prints generated code for every
      # aggregate in the domain.
      #
      # @param aggregate_name [String, nil] optional name of a single aggregate to preview
      # @return [nil]
      def preview(aggregate_name = nil)
        domain = to_domain

        if aggregate_name
          puts Hecks.preview(domain, aggregate_name)
        else
          domain.aggregates.each do |agg|
            puts "# === #{agg.name} ==="
            puts Hecks.preview(domain, agg.name)
            puts
          end
        end
        nil
      end

      # Build the domain into a gem on disk.
      #
      # Compiles all aggregates into a versioned Ruby gem. If no version is
      # specified, automatically increments using CalVer via the Versioner.
      #
      # @param version [String, nil] explicit version string (default: auto-incremented CalVer)
      # @param output_dir [String] directory to write the gem into (default: ".")
      # @return [String] path to the generated gem directory
      def build(version: nil, output_dir: ".")
        domain = to_domain
        version ||= next_version
        path = Hecks.build(domain, version: version, output_dir: output_dir)
        puts "Built #{domain.gem_name} v#{version} -> #{path}/"
        path
      end

      # Save the current domain definition as DSL source code.
      #
      # Serializes the domain to a Ruby file that can be loaded later
      # to reconstruct the same domain definition.
      #
      # @param path [String] file path to write to (default: "Bluebook")
      # @return [String] the path that was written
      def save(path = "Bluebook")
        File.write(path, to_dsl)
        puts "Saved to #{path}"
        path
      end

      # Serialize the current domain definition to DSL source code string.
      #
      # @return [String] Ruby source code that reconstructs this domain
      def to_dsl
        DslSerializer.new(to_domain).serialize
      end

      private

      # Count total commands across all aggregates in the domain.
      #
      # @param domain [DomainModel::Structure::Domain] the domain to inspect
      # @return [Integer] total command count
      def total_commands(domain)
        domain.aggregates.sum { |a| a.commands.size }
      end

      # Count total events across all aggregates in the domain.
      #
      # @param domain [DomainModel::Structure::Domain] the domain to inspect
      # @return [Integer] total event count
      def total_events(domain)
        domain.aggregates.sum { |a| a.events.size }
      end

      # Determine the next version number using CalVer.
      #
      # @return [String] the next version string (e.g. "2026.03.26.1")
      def next_version
        Versioner.new(".").next
      end
    end
  end
end
