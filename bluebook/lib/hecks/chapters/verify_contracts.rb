# Hecks::Chapters::ContractVerifier
#
# Runs every data contract against every aggregate, command, event,
# and attribute in every Bluebook chapter. The chapters ARE the test
# data — Hecks verifies itself.
#
#   Hecks::Chapters::ContractVerifier.run
#   Hecks::Chapters::ContractVerifier.run(format: :documentation)
#
module Hecks
  module Chapters
    module ContractVerifier
      Result = Struct.new(:pass_count, :errors)

      def self.run(format: :progress)
        result = Result.new(0, [])

        chapter_modules = Chapters.constants
          .map { |c| Chapters.const_get(c) }
          .select { |m| m.respond_to?(:definition) }

        chapter_modules.each do |mod|
          domain = mod.definition
          next if domain.aggregates.empty?

          puts "\e[1m#{domain.name}\e[0m" if format == :documentation

          domain.aggregates.each do |agg|
            puts "  \e[1m#{agg.name}\e[0m" if format == :documentation
            verify_aggregate(result, format, domain, agg)
            puts "" if format == :documentation
          end
        end

        result
      end

      def self.verify_aggregate(result, format, domain, agg)
        ctx = "#{domain.name}/#{agg.name}"

        check(result, format, ctx, "AggregateContract.rules") do
          rules = Hecks::Conventions::AggregateContract.rules(agg)
          raise "no standard_fields" unless rules[:standard_fields]&.any?
        end

        check(result, format, ctx, "AggregateContract.partition_commands") do
          creates, updates = Hecks::Conventions::AggregateContract.partition_commands(agg)
          raise "partition lost commands" unless creates.size + updates.size == agg.commands.size
        end

        check(result, format, ctx, "Names.slug + snake") do
          raise "blank slug" if Hecks::Conventions::Names.bluebook_aggregate_slug(agg.name).to_s.empty?
          raise "blank snake" if Hecks::Conventions::Names.bluebook_snake_name(agg.name).to_s.empty?
        end

        verify_commands(result, format, domain, agg)
        verify_events(result, format, domain, agg)
        verify_attributes(result, format, domain, agg)
        verify_lifecycle(result, format, domain, agg)
        verify_validations(result, format, domain, agg)
        verify_display(result, format, domain, agg)
        verify_ui_labels(result, format, domain, agg)
        verify_view_contracts(result, format, domain, agg)
        verify_form_parsing(result, format, domain, agg)
        verify_event_log(result, format, domain, agg)
      end

      def self.verify_commands(result, format, domain, agg)
        agg.commands.each do |cmd|
          ctx = "#{domain.name}/#{agg.name}/#{cmd.name}"

          check(result, format, ctx, "CommandContract.method_name") do
            method = Hecks::Conventions::CommandContract.method_name(cmd.name, agg.name)
            raise "not a symbol" unless method.is_a?(Symbol)
            raise "empty" if method.to_s.empty?
          end

          slug = Hecks::Conventions::Names.bluebook_aggregate_slug(agg.name)
          cmd_snake = Hecks::Utils.underscore(cmd.name)

          check(result, format, ctx, "RouteContract.form_path") do
            path = Hecks::Conventions::RouteContract.form_path(slug, cmd_snake)
            raise "blank" if path.to_s.empty?
            raise "no leading slash" unless path.start_with?("/")
          end

          check(result, format, ctx, "RouteContract.submit_path") do
            path = Hecks::Conventions::RouteContract.submit_path(slug, cmd_snake)
            raise "blank" if path.to_s.empty?
          end
        end
      end

      def self.verify_events(result, format, domain, agg)
        agg.events.each do |event|
          ctx = "#{domain.name}/#{agg.name}/#{event.name}"

          check(result, format, ctx, "EventContract.REQUIRED_FIELDS") do
            Hecks::Conventions::EventContract::REQUIRED_FIELDS.each do |field, types|
              raise "missing #{field} ruby mapping" unless types[:ruby]
              raise "missing #{field} go mapping" unless types[:go]
            end
          end
        end
      end

      def self.verify_attributes(result, format, domain, agg)
        agg.attributes.each do |attr|
          %i[go sql json openapi typescript].each do |target|
            check(result, format, "#{domain.name}/#{agg.name}.#{attr.name}",
              "TypeContract.for(:#{target}, #{attr.type})") do
              mapped = Hecks::Conventions::TypeContract.for(target, attr.type)
              raise "nil mapping" if mapped.nil?
            end
          end
        end
      end

      def self.verify_lifecycle(result, format, domain, agg)
        return unless agg.lifecycle

        check(result, format, "#{domain.name}/#{agg.name}", "AggregateContract.lifecycle") do
          lc = Hecks::Conventions::AggregateContract.rules(agg)[:lifecycle]
          raise "no field" unless lc[:field]
          raise "no default" unless lc[:default]
          raise "no states" unless lc[:states]&.any?
        end
      end

      def self.verify_validations(result, format, domain, agg)
        return unless agg.validations.any?

        check(result, format, "#{domain.name}/#{agg.name}", "AggregateContract.validations") do
          Hecks::Conventions::AggregateContract.rules(agg)[:validations].each do |v|
            raise "missing field" unless v[:field]
            raise "missing check" unless v[:check]
          end
        end
      end

      def self.verify_display(result, format, domain, agg)
        ctx = "#{domain.name}/#{agg.name}"

        check(result, format, ctx, "DisplayContract.aggregate_summary") do
          summary = Hecks::Conventions::DisplayContract.aggregate_summary(agg)
          raise "no commands key" unless summary.key?(:commands)
          raise "no ports key" unless summary.key?(:ports)
        end

        agg.attributes.each do |attr|
          check(result, format, "#{ctx}.#{attr.name}", "DisplayContract.cell_expression(:ruby)") do
            expr = Hecks::Conventions::DisplayContract.cell_expression(attr, "obj", lang: :ruby, domain: domain)
            raise "nil expression" if expr.nil?
          end

          check(result, format, "#{ctx}.#{attr.name}", "DisplayContract.cell_expression(:go)") do
            expr = Hecks::Conventions::DisplayContract.cell_expression(attr, "obj", lang: :go, domain: domain)
            raise "nil expression" if expr.nil?
          end
        end

        if agg.lifecycle
          check(result, format, ctx, "DisplayContract.lifecycle_transitions") do
            labels = Hecks::Conventions::DisplayContract.lifecycle_transitions(agg.lifecycle)
            raise "not an array" unless labels.is_a?(Array)
          end
        end
      end

      def self.verify_ui_labels(result, format, domain, agg)
        ctx = "#{domain.name}/#{agg.name}"

        check(result, format, ctx, "UILabelContract.label") do
          label = Hecks::Conventions::UILabelContract.label(agg.name)
          raise "blank" if label.to_s.empty?
        end

        check(result, format, ctx, "UILabelContract.plural_label") do
          label = Hecks::Conventions::UILabelContract.plural_label(agg.name)
          raise "blank" if label.to_s.empty?
        end

        agg.attributes.each do |attr|
          check(result, format, "#{ctx}.#{attr.name}", "UILabelContract.label") do
            label = Hecks::Conventions::UILabelContract.label(attr.name)
            raise "blank" if label.to_s.empty?
          end
        end

        agg.commands.each do |cmd|
          check(result, format, "#{ctx}/#{cmd.name}", "UILabelContract.label") do
            label = Hecks::Conventions::UILabelContract.label(cmd.name)
            raise "blank" if label.to_s.empty?
          end
        end
      end

      def self.verify_view_contracts(result, format, domain, agg)
        ctx = "#{domain.name}/#{agg.name}"

        Hecks::Conventions::ViewContract.all.each do |template_name, contract|
          check(result, format, ctx, "ViewContract.#{template_name}") do
            raise "no fields" unless contract[:fields]&.any?
            raise "no name" unless contract[:name]
          end

          check(result, format, ctx, "ViewContract.go_struct(:#{template_name})") do
            struct = Hecks::Conventions::ViewContract.go_struct(template_name, contract[:fields])
            raise "blank struct" if struct.to_s.empty?
            raise "no type keyword" unless struct.include?("type")
          end
        end
      end

      def self.verify_form_parsing(result, format, domain, agg)
        agg.attributes.each do |attr|
          go_type = Hecks::Conventions::TypeContract.for(:go, attr.type)

          check(result, format, "#{domain.name}/#{agg.name}.#{attr.name}",
            "FormParsingContract.input_type(#{go_type})") do
            input = Hecks::Conventions::FormParsingContract.input_type(go_type)
            raise "nil input type" if input.nil?
          end

          check(result, format, "#{domain.name}/#{agg.name}.#{attr.name}",
            "FormParsingContract.go_parse_line") do
            go_field = Hecks::Utils.sanitize_constant(attr.name)
            line = Hecks::Conventions::FormParsingContract.go_parse_line(attr.name.to_s, go_field, go_type)
            raise "blank" if line.to_s.empty?
          end

          check(result, format, "#{domain.name}/#{agg.name}.#{attr.name}",
            "FormParsingContract.ruby_coerce") do
            ruby_type = Hecks::Conventions::TypeContract.for(:json, attr.type)
            expr = Hecks::Conventions::FormParsingContract.ruby_coerce(attr.name.to_s, ruby_type)
            raise "blank" if expr.to_s.empty?
          end
        end
      end

      def self.verify_event_log(result, format, domain, agg)
        return unless agg.events.any?
        ctx = "#{domain.name}/#{agg.name}"

        check(result, format, ctx, "EventLogContract.FIELDS") do
          raise "no fields" unless Hecks::Conventions::EventLogContract::FIELDS.any?
        end

        check(result, format, ctx, "EventLogContract.go_struct") do
          struct = Hecks::Conventions::EventLogContract.go_struct
          raise "blank" if struct.to_s.empty?
          raise "no json tag" unless struct.include?("json:")
        end

        check(result, format, ctx, "EventLogContract.go_mapper") do
          mapper = Hecks::Conventions::EventLogContract.go_mapper
          raise "blank" if mapper.to_s.empty?
        end

        check(result, format, ctx, "EventLogContract.ruby_mapper") do
          mapper = Hecks::Conventions::EventLogContract.ruby_mapper
          raise "blank" if mapper.to_s.empty?
        end
      end

      def self.check(result, format, context, contract)
        yield
        result.pass_count += 1
        if format == :documentation
          puts "    \e[32m✓\e[0m #{contract}"
        else
          print "."
        end
      rescue => e
        result.errors << { context: context, message: "#{contract}: #{e.message}" }
        if format == :documentation
          puts "    \e[31m✗\e[0m #{contract}: #{e.message}"
        else
          print "\e[31mF\e[0m"
        end
      end
    end
  end
end
