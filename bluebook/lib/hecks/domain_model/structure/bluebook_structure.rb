module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::BluebookStructure
    #
    # Container IR node representing a composed system of domains (chapters).
    # A Bluebook is the top-level composition unit — it holds multiple Chapter
    # domains that share an event bus and can wire cross-chapter policies.
    #
    #   bluebook = BluebookStructure.new(
    #     name: "PizzaShop",
    #     chapters: [pizzas_domain, billing_domain]
    #   )
    #   bluebook.chapters.map(&:name)  # => ["Pizzas", "Billing"]
    #
    class BluebookStructure
      # @return [String] the system name (e.g., "PizzaShop")
      attr_reader :name

      # @return [Domain, nil] the binding — bootstrap layer holding chapters together
      attr_reader :binding

      # @return [Array<Domain>] the chapter domains composing this bluebook
      attr_reader :chapters

      # @return [String, nil] optional version
      attr_reader :version

      # @param name [String] the bluebook/system name
      # @param binding [Domain, nil] the binding domain (spine/bootstrap)
      # @param chapters [Array<Domain>] the chapter domain IR objects
      # @param version [String, nil] optional version string
      def initialize(name:, binding: nil, chapters: [], version: nil)
        @name = name
        @binding = binding
        @chapters = chapters
        @version = version
      end

      # All reactive policies across all chapters.
      #
      # @return [Array<Behavior::Policy>]
      def all_policies
        chapters.flat_map(&:reactive_policies)
      end

      # All commands across all chapters.
      #
      # @return [Array<Behavior::Command>]
      def all_commands
        chapters.flat_map(&:all_commands)
      end

      # All events across all chapters.
      #
      # @return [Array<Behavior::DomainEvent>]
      def all_events
        chapters.flat_map(&:all_events)
      end

      # Find which chapter owns a given command.
      #
      # @param command_name [String]
      # @return [Domain, nil]
      def chapter_for_command(command_name)
        chapters.find { |ch| ch.aggregate_for_command(command_name) }
      end

      # All domains in this bluebook (binding + chapters).
      #
      # @return [Array<Domain>]
      def all_domains
        [binding, *chapters].compact
      end

      # Print the Ubiquitous Language glossary for the entire bluebook.
      # Walks binding + all chapters, printing each domain's terms.
      #
      #   Hecks::Chapters.bluebook.glossary
      #
      # @return [nil]
      def glossary
        all_domains.each do |domain|
          puts "── #{domain.name} ──"
          domain.aggregates.each do |agg|
            desc = agg.respond_to?(:description) ? agg.description : nil
            puts "  #{agg.name}#{desc ? " — #{desc}" : ""}"
            agg.commands.each do |cmd|
              cmd_desc = cmd.respond_to?(:description) ? cmd.description : nil
              puts "    #{cmd.name}#{cmd_desc ? " — #{cmd_desc}" : ""}"
            end
          end
          puts
        end
        nil
      end
    end
    end
  end
end
