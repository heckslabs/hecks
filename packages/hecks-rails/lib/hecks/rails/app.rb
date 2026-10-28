require "hecks/projections/site/root_rows"

module Hecks
  module Rails
    # What the generated pages show of the app as a whole: its title, its navigation and the
    # columns of each list. All of it comes from the booted domain, and the `App` and `Listing`
    # rows of the RailsApp bluebook change it. With no rows the pages still work.
    module App
      # One place in the navigation.
      Entry = Struct.new(:model, :label, :path, keyword_init: true)

      # The rows a project may declare, checked against the RailsApp bluebook's shapes.
      APP_ROW = Hecks::Projections::Site::RootRows.new("App", fields: { title: String, home: String }, required: [:title])
      LISTING_ROWS = Hecks::Projections::Site::RootRows.new(
        "Listing", fields: { aggregate: String, label: String, columns: String }, required: [:aggregate], many: true
      )

      module_function

      # @return [String] the name the pages carry: the `App` row's, else the Rails application's own
      def title = app_row.fetch(:title) { Naming.words(::Rails.application.class.module_parent_name.to_s.underscore) }

      # @return [Array<Entry>] a place for each aggregate that takes commands, in the order
      #   declared, the `App` row's home first
      def entries
        found = Booted.app_bluebooks.flat_map(&:aggregates).select { |a| a.commands.any? }.filter_map { |a| entry(a) }
        home, rest = found.partition { |entry| entry.model.name == app_row[:home] }
        home + rest
      end

      # @return [Array<String>] every role a command of the app's aggregates names, in order seen
      def roles
        Booted.app_bluebooks.flat_map(&:aggregates).flat_map(&:commands).filter_map(&:role).map(&:to_s).uniq
      end

      # @param model [Class] an aggregate's model
      # @return [Array<Symbol>] the attributes its list shows: the `Listing` row's, else identity,
      #   lifecycle state and the first scalars
      # @raise [ArgumentError] when a `Listing` row names an attribute the aggregate lacks
      def columns(model)
        named = listing(model.door.ir.hecks_name)[:columns]
        return Hecks::Forms::RecordTable.columns(model.door.ir) unless named

        named.split(",").map { |column| column.strip.to_sym }.tap { |columns| known!(model, columns) }
      end

      # @param aggregate [Hecks::Bluebook::Aggregate] an aggregate of the booted domain
      # @return [Entry, nil] its place, or nil when the app has no model for it
      def entry(aggregate)
        model = aggregate.hecks_name.safe_constantize
        return unless model.is_a?(Class) && model < Model

        plural = Naming.plural(Naming.snake(aggregate.hecks_name)).to_s
        Entry.new(model: model, label: listing(aggregate.hecks_name).fetch(:label) { Naming.words(plural) }, path: "/#{plural}")
      end

      def app_row = declarations.flat_map { |declaration| APP_ROW.read(declaration) }.first || {}

      def listing(aggregate_name)
        rows = declarations.flat_map { |declaration| LISTING_ROWS.read(declaration) }
        rows.find { |row| row[:aggregate] == aggregate_name } || {}
      end

      def declarations = Booted.app_bluebooks

      def known!(model, columns)
        known = [*model.door.ir.attributes.map(&:name), model.door.ir.lifecycle_field, :id].compact
        unknown = columns - known
        raise ArgumentError, "Listing #{model.name} names #{unknown.join(", ")}, which it lacks" if unknown.any?
      end
    end
  end
end
