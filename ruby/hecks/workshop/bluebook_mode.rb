module Hecks
  class Workshop

    # Hecks::Workshop::BluebookMode
    #
    # Mixin for composing multiple domains (chapters) in a single workshop.
    # Each chapter is a nested Workshop instance. Play mode compiles all
    # chapters and boots them with a shared event bus via Hecks.open.
    #
    #   workshop = Hecks.workshop("PizzaShop")
    #   workshop.chapter("Pizzas") { aggregate("Pizza") { attribute :name, String } }
    #   workshop.chapter("Billing") { aggregate("Invoice") { attribute :amount, Float } }
    #   workshop.play!   # boots all chapters with cross-chapter event wiring
    #
    module BluebookMode
      # Define or access a chapter (sub-domain) within this workshop.
      #
      # Creates a nested Workshop for the chapter if it doesn't exist.
      # If a block is given, it is evaluated in the chapter workshop's context.
      #
      # @param name [String] the chapter/domain name
      # @yield optional block evaluated in the chapter workshop
      # @return [Workshop] the chapter workshop
      def chapter(name, &block)
        @chapters ||= {}
        ch = @chapters[name] ||= Workshop.new(name)
        ch.instance_eval(&block) if block
        @current_chapter = name
        ch
      end

      # List all chapter names.
      #
      # @return [Array<String>]
      def chapters
        (@chapters || {}).keys
      end

      # Get the currently focused chapter workshop.
      #
      # @return [Workshop, nil]
      def current_chapter
        return nil unless @current_chapter
        @chapters&.dig(@current_chapter)
      end

      # Check if this workshop has chapters (is in bluebook mode).
      #
      # @return [Boolean]
      def bluebook?
        @chapters && !@chapters.empty?
      end

      # Build a BluebookStructure IR from all chapters.
      #
      # @return [BluebookModel::Structure::BluebookStructure]
      def to_bluebook
        domains = @chapters.values.map(&:to_domain)
        BluebookModel::Structure::BluebookStructure.new(
          name: @name, chapters: domains
        )
      end
    end
  end
end
