module Hecks
  module Rails
    # Helpers for the pages the gem ships: what a list shows of a record, and which of a record's
    # commands to offer. Included into every view.
    module Pages
      # @param model [Class] an aggregate's model
      # @return [Array<Symbol>] the attributes a list shows (see `App.columns`)
      def hecks_columns(model) = App.columns(model)

      # @param record [Hecks::Rails::Model] a record
      # @param column [Symbol] one of its attributes
      # @return [String] the value in words, a value object flattened to its parts
      def hecks_cell(record, column) = hecks_words(Hecks::Runtime::Value.materialize(record.to_h[column]))

      # @param model [Class] an aggregate's model
      # @return [String] the heading its list carries: the `Listing` row's label, else its plural
      def hecks_label(model) = App.entry(model.door.ir).label

      # @param column [Symbol, String] an attribute's name
      # @return [String] the heading a list gives it
      def hecks_heading(column) = Naming.words(column)

      # @param model [Class] an aggregate's model
      # @return [Array<Hecks::Bluebook::Command>] the commands that make a new record
      def hecks_creators(model) = model.door.ir.commands.select(&:creates?)

      # @param record [Hecks::Rails::Model] a record
      # @return [Array<Array<Hecks::Bluebook::Command>>] the commands the actor may run now, then
      #   the rest, which the domain would refuse
      def hecks_commands_for(record)
        offered = record.available_commands(as: hecks_actor_id)
        record.class.door.ir.commands.reject(&:creates?).partition do |command|
          offered.include?(Naming.snake(command.hecks_name).to_sym)
        end
      end

      # @return [String] who the pages act as; "anonymous" when nobody is signed in
      def hecks_actor_id = (controller.hecks_actor || {}).fetch(:actor_id, Controller::ANONYMOUS)

      # @param command [Hecks::Bluebook::Command] a command
      # @return [String] its bare verb, as the route and the form helper name it
      def hecks_verb(command) = Naming.snake(command.hecks_name).to_s

      private

      def hecks_words(value)
        case value
        when Hash then value.size == 1 ? hecks_words(value.values.first) : hecks_pairs(value)
        when Array then value.map { |item| hecks_words(item) }.join("; ")
        else value.to_s
        end
      end

      def hecks_pairs(hash) = hash.map { |key, item| "#{Naming.words(key).downcase}: #{hecks_words(item)}" }.join(", ")
    end
  end
end

ActiveSupport.on_load(:action_view) { include Hecks::Rails::Pages }
