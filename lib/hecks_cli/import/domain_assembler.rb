module Hecks
  module Import
    # Hecks::Import::DomainAssembler
    #
    # Combines schema data and model data into a valid Hecks DSL source
    # string. Maps Rails column types to Hecks types, converts foreign
    # keys to references, generates Create commands, and wires up
    # validations, enums, and state machines from model enrichment.
    #
    #   DomainAssembler.new(schema_data, model_data, domain_name: "Blog").assemble
    #   # => 'Hecks.domain "Blog" do ...'
    #
    class DomainAssembler
      RAILS_TO_HECKS = {
        string: "String", text: "String",
        integer: "Integer", bigint: "Integer",
        float: "Float", decimal: "Float",
        boolean: "TrueClass",
        date: "Date", datetime: "DateTime", timestamp: "DateTime",
        json: "JSON", jsonb: "JSON",
        binary: "String", uuid: "String"
      }.freeze

      def initialize(schema_data, model_data = {}, domain_name: "MyDomain")
        @schema_data = schema_data
        @model_data  = model_data
        @domain_name = domain_name
      end

      def assemble
        lines = ["Hecks.domain \"#{@domain_name}\" do"]
        @schema_data.each_with_index do |table, i|
          lines << "" if i > 0
          lines.concat(assemble_aggregate(table))
        end
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      def assemble_aggregate(table)
        agg_name = classify(table[:name])
        model    = @model_data[agg_name] || {}
        enums    = model[:enums] || {}
        lines    = ["  aggregate \"#{agg_name}\" do"]

        # Attributes
        table[:columns].each do |col|
          lines << assemble_attribute(col, enums)
        end

        # Validations from model
        (model[:validations] || []).each do |v|
          lines << "    validation :#{v[:field]}, #{v[:rules].inspect}"
        end

        # Lifecycle from state machine
        if (sm = model[:state_machine])
          lines << ""
          default = sm[:initial] ? ", default: \"#{sm[:initial]}\"" : ""
          lines << "    lifecycle :#{sm[:field]}#{default} do"
          sm[:transitions].each do |t|
            cmd_name = classify(t[:event]) + agg_name
            lines << "      transition \"#{cmd_name}\" => \"#{t[:to]}\""
          end
          lines << "    end"
        end

        # Create command with writable attributes
        writable = table[:columns].reject { |c| c[:type] == :reference }
        if writable.any?
          lines << ""
          lines << "    command \"Create#{agg_name}\" do"
          writable.each do |col|
            hecks_type = RAILS_TO_HECKS[col[:type]] || "String"
            lines << "      attribute :#{col[:name]}, #{hecks_type}"
          end
          lines << "    end"
        end

        lines << "  end"
        lines
      end

      def assemble_attribute(col, enums)
        if col[:type] == :reference
          target = classify(col[:target])
          "    reference_to \"#{target}\""
        elsif enums.key?(col[:name])
          values = enums[col[:name]].map(&:to_s)
          "    attribute :#{col[:name]}, String, enum: #{values.inspect}"
        else
          hecks_type = RAILS_TO_HECKS[col[:type]] || "String"
          "    attribute :#{col[:name]}, #{hecks_type}"
        end
      end

      def classify(table_name)
        table_name.to_s
          .sub(/_id$/, "")
          .split("_")
          .map(&:capitalize)
          .join
          .sub(/ies$/, "y")
          .sub(/sses$/, "ss")
          .sub(/([^s])ses$/, '\1se')
          .sub(/s$/, "")
          .then { |s| s.empty? ? table_name.to_s : s }
      end
    end
  end
end
