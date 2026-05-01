module Hecks
  module Import
    # Hecks::Import::ModelOnlyAssembler
    #
    # Builds a Hecks DSL domain definition from Rails model files alone,
    # without requiring a schema.rb. Derives structure from ActiveRecord
    # associations, validations, enums, and AASM state machines.
    #
    #   models = ModelParser.new("app/models").parse
    #   ModelOnlyAssembler.new(models, domain_name: "Blog").assemble
    #   # => 'Hecks.domain "Blog" do ...'
    #
    class ModelOnlyAssembler
      def initialize(model_data, domain_name: "MyDomain")
        @model_data  = model_data
        @domain_name = domain_name
      end

      def assemble
        lines = ["Hecks.domain \"#{@domain_name}\" do"]
        @model_data.each_with_index do |(class_name, model), i|
          lines << "" if i > 0
          lines.concat(assemble_aggregate(class_name, model))
        end
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      def assemble_aggregate(class_name, model)
        enums  = model[:enums] || {}
        assocs = model[:associations] || []
        lines  = ["  aggregate \"#{class_name}\" do"]

        lines.concat(assemble_associations(assocs))
        lines.concat(assemble_enum_attributes(enums))
        lines.concat(assemble_validations(model[:validations] || []))
        lines.concat(assemble_lifecycle(model[:state_machine], class_name))

        lines << "  end"
        lines
      end

      def assemble_associations(associations)
        lines = []
        associations.each do |assoc|
          case assoc[:type]
          when :belongs_to
            target = classify(assoc[:name])
            lines << "    reference_to \"#{target}\""
          when :has_many
            next if assoc[:through] # skip join-table associations
            target = classify(assoc[:name])
            lines << "    list_of \"#{target}\""
          when :has_one
            target = classify(assoc[:name])
            lines << "    reference_to \"#{target}\""
          end
        end
        lines
      end

      def assemble_enum_attributes(enums)
        enums.map do |field, values|
          "    attribute :#{field}, String, enum: #{values.map(&:to_s).inspect}"
        end
      end

      def assemble_validations(validations)
        validations.map do |v|
          "    validation :#{v[:field]}, #{v[:rules].inspect}"
        end
      end

      def assemble_lifecycle(state_machine, class_name)
        return [] unless state_machine

        lines = [""]
        default = state_machine[:initial] ? ", default: \"#{state_machine[:initial]}\"" : ""
        lines << "    lifecycle :#{state_machine[:field]}#{default} do"
        state_machine[:transitions].each do |t|
          cmd_name = classify(t[:event]) + class_name
          lines << "      transition \"#{cmd_name}\" => \"#{t[:to]}\""
        end
        lines << "    end"
        lines
      end

      def classify(name)
        name.to_s
          .split("_")
          .map(&:capitalize)
          .join
          .sub(/ies$/, "y")
          .sub(/sses$/, "ss")
          .sub(/([^s])ses$/, '\1se')
          .sub(/s$/, "")
          .then { |s| s.empty? ? name.to_s : s }
      end
    end
  end
end
