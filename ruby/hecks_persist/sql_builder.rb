module Hecks
  module Generators
    module SQL
      # Hecks::Generators::SQL::SqlBuilder
      #
      # Mixin with Sequel-based generation helpers for SqlAdapterGenerator. Builds
      # insert, update, build, and delete method bodies using Sequel dataset
      # operations. Handles join tables for list-type value objects. Part of
      # Generators::SQL, mixed into SqlAdapterGenerator.
      #
      #   # Mixed into SqlAdapterGenerator:
      #   insert_lines  # => ["      def insert(pizza)", ...]
      #
      module SqlBuilder
        include HecksTemplating::NamingHelpers
      private

      # Generates the insert method body for saving a new aggregate to the database.
      #
      # Produces a method that inserts scalar attributes into the main table
      # and iterates over list value objects to insert into join tables.
      # JSON attributes are serialized with JSON.generate.
      #
      # @return [Array<String>] lines of Ruby source code for the insert method
      def insert_lines
        col_hash = scalar_attributes.map { |a| a.json? ? "#{a.name}: JSON.generate(#{snake_name}.#{a.name} || nil)" : "#{a.name}: #{snake_name}.#{a.name}" }
        (@aggregate.references || []).each do |ref|
          col_hash << "#{ref.name}_id: (#{snake_name}.#{ref.name}.respond_to?(:id) ? #{snake_name}.#{ref.name}.id : #{snake_name}.#{ref.name})"
        end
        col_hash << "id: #{snake_name}.id"
        col_hash << "created_at: #{snake_name}.created_at&.iso8601"
        col_hash << "updated_at: #{snake_name}.updated_at&.iso8601"

        lines = []
        lines << "      def insert(#{snake_name})"
        lines << "        @db[:#{table_name}].insert(#{col_hash.join(', ')})"
        list_value_objects.each do |vo|
          lines.concat(insert_vo_lines(vo))
        end
        lines << "      end"
        lines
      end

      # Generates the update method body for updating an existing aggregate.
      #
      # Updates scalar attributes on the main table, then replaces all
      # join table rows for list value objects (delete + re-insert).
      # JSON attributes are serialized with JSON.generate.
      #
      # @return [Array<String>] lines of Ruby source code for the update method
      def update_lines
        col_hash = scalar_attributes.map { |a| a.json? ? "#{a.name}: JSON.generate(#{snake_name}.#{a.name} || nil)" : "#{a.name}: #{snake_name}.#{a.name}" }
        (@aggregate.references || []).each do |ref|
          col_hash << "#{ref.name}_id: (#{snake_name}.#{ref.name}.respond_to?(:id) ? #{snake_name}.#{ref.name}.id : #{snake_name}.#{ref.name})"
        end
        col_hash << "created_at: #{snake_name}.created_at&.iso8601"
        col_hash << "updated_at: #{snake_name}.updated_at&.iso8601"

        lines = []
        lines << "      def update(#{snake_name})"
        if scalar_attributes.any?
          lines << "        @db[:#{table_name}].where(id: #{snake_name}.id).update(#{col_hash.join(', ')})"
        end
        list_value_objects.each do |vo|
          vo_table = "#{table_name}_#{domain_snake_name(vo.name)}s"
          lines << "        @db[:#{vo_table}].where(#{snake_name}_id: #{snake_name}.id).delete"
          lines.concat(insert_vo_lines(vo))
        end
        lines << "      end"
        lines
      end

      # Generates the build method body for constructing an aggregate from a DB row.
      #
      # Loads join table rows for list value objects, constructs VO instances,
      # and assembles the aggregate with all attributes. Parses created_at and
      # updated_at timestamps from stored strings.
      #
      # @return [Array<String>] lines of Ruby source code for the build method
      def build_lines
        attr_assigns = scalar_attributes.map do |a|
          if a.json?
            "          #{a.name}: (row[:#{a.name}] ? JSON.parse(row[:#{a.name}]) : nil)"
          else
            "          #{a.name}: row[:#{a.name}]"
          end
        end
        # Reference columns stored as _id in DB; pass raw ID into role attr for hydration
        (@aggregate.references || []).each do |ref|
          attr_assigns << "          #{ref.name}: row[:#{ref.name}_id]"
        end

        lines = []
        lines << "      def build(row)"

        list_value_objects.each do |vo|
          vo_table = "#{table_name}_#{domain_snake_name(vo.name)}s"
          vo_snake = domain_snake_name(vo.name)
          lines << "        #{vo_snake}_rows = @db[:#{vo_table}].where(#{snake_name}_id: row[:id]).all"
          vo_attrs = vo.attributes.map { |a| "#{a.name}: r[:#{a.name}]" }.join(", ")
          lines << "        #{vo_snake}s = #{vo_snake}_rows.map { |r| #{domain_constant_name(@aggregate.name)}::#{vo.name}.new(#{vo_attrs}) }"
        end

        all_assigns = ["          id: row[:id]"] + attr_assigns
        list_value_objects.each do |vo|
          attr_name = @aggregate.attributes.find { |a| a.list? && a.type.to_s == vo.name }&.name
          all_assigns << "          #{attr_name}: #{domain_snake_name(vo.name)}s" if attr_name
        end
        lines << "        require \"time\""
        lines << "        agg = #{domain_constant_name(@aggregate.name)}.new("
        lines << all_assigns.join(",\n")
        lines << "        )"
        lines << "        agg.instance_variable_set(:@created_at, row[:created_at] ? Time.parse(row[:created_at].to_s) : nil)"
        lines << "        agg.instance_variable_set(:@updated_at, row[:updated_at] ? Time.parse(row[:updated_at].to_s) : nil)"
        lines << "        agg"
        lines << "      end"
        lines
      end

      # Generates insert statements for a value object's join table rows.
      #
      # Produces a loop that inserts each VO instance with a new UUID,
      # the parent aggregate's ID as foreign key, and all VO attributes.
      #
      # @param vo [BluebookModel::Structure::ValueObject] the value object
      # @return [Array<String>] lines of Ruby source code for the VO insert loop
      def insert_vo_lines(vo)
        vo_table = "#{table_name}_#{domain_snake_name(vo.name)}s"
        attr_name = @aggregate.attributes.find { |a| a.list? && a.type.to_s == vo.name }&.name
        return [] unless attr_name

        vo_cols = vo.attributes.map { |a| "#{a.name}: vo.#{a.name}" }

        lines = []
        lines << "        #{snake_name}.#{attr_name}.each do |vo|"
        lines << "          @db[:#{vo_table}].insert(id: SecureRandom.uuid, #{snake_name}_id: #{snake_name}.id, #{vo_cols.join(', ')})"
        lines << "        end"
        lines
      end

      # Generates delete statements for value object join table rows.
      #
      # Produces statements that delete all join table rows for a given
      # aggregate ID before the aggregate itself is deleted.
      #
      # @return [Array<String>] lines of Ruby source code for VO deletion
      def delete_vo_lines
        lines = []
        list_value_objects.each do |vo|
          vo_table = "#{table_name}_#{domain_snake_name(vo.name)}s"
          lines << "        @db[:#{vo_table}].where(#{snake_name}_id: id).delete"
        end
        lines
      end
      end
    end
  end
end
