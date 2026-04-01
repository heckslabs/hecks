# GoHecks::CommandGenerator
#
# Generates a Go struct for a command with an Execute method.
# Create commands build a new aggregate; update commands look up
# an existing one by ID and merge changed attributes.
#
module GoHecks
  class CommandGenerator
    include GoUtils

    def initialize(command, aggregate:, event:, package:)
      @cmd = command
      @agg = aggregate
      @event = event
      @package = package
      suffixes = HecksTemplating::CommandContract.agg_suffixes(@agg.name)
      @self_id = @cmd.attributes.find { |a|
        a.name.to_s.end_with?("_id") &&
          suffixes.any? { |s| a.name.to_s == "#{s}_id" }
      }
      @is_create = @self_id.nil?
      # Event type name in Go — suffixed if it collides with command name
      @go_event_name = @event.name == @cmd.name ? "#{@event.name}Event" : @event.name
    end

    def generate
      lines = []
      lines << "package #{@package}"
      lines << ""
      imports = ["\"time\""]
      imports << "\"fmt\"" unless @is_create
      lines << "import ("
      imports.each { |i| lines << "\t#{i}" }
      lines << ")"
      lines << ""

      # Command struct
      lines << "type #{@cmd.name} struct {"
      @cmd.attributes.each do |attr|
        field = GoUtils.pascal_case(attr.name)
        go_t = GoUtils.go_type(attr)
        tag = GoUtils.json_tag(attr.name)
        lines << "\t#{field} #{go_t} `json:\"#{tag}\"`"
      end
      lines << "}"
      lines << ""

      lines << "func (c #{@cmd.name}) CommandName() string { return \"#{@cmd.name}\" }"
      lines << ""

      # Execute method
      lines << "func (c #{@cmd.name}) Execute(repo #{@agg.name}Repository) (*#{@agg.name}, *#{@go_event_name}, error) {"
      if @is_create
        lines.concat(create_body)
      else
        lines.concat(update_body)
      end
      lines << "}"

      lines.join("\n") + "\n"
    end

    private

    def create_body
      agg_attrs = @agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
      lines = []

      # Check for VO append: command attrs match a value object's attrs
      vo_appends = {}
      agg_attrs.each do |a|
        next unless a.list?
        vo = @agg.value_objects.find { |v| v.name == a.type.to_s }
        next unless vo
        vo_attr_names = vo.attributes.map { |va| va.name.to_s }
        cmd_attr_names = @cmd.attributes.map { |ca| ca.name.to_s }
        matching = vo_attr_names & cmd_attr_names
        if matching.size >= vo_attr_names.size
          vo_appends[a.name.to_s] = { vo: vo, attrs: matching }
        end
      end

      # Build VO items before constructing aggregate
      vo_appends.each do |attr_name, info|
        vo = info[:vo]
        vo_args = info[:attrs].map { |n| "c.#{GoUtils.pascal_case(n)}" }.join(", ")
        var_name = GoUtils.camel_case(vo.name) + "Item"
        lines << "\t#{var_name}, err := New#{vo.name}(#{vo_args})"
        lines << "\tif err != nil { return nil, nil, err }"
      end

      # Map command attrs to constructor params
      constructor_args = agg_attrs.map do |a|
        if vo_appends[a.name.to_s]
          vo = vo_appends[a.name.to_s][:vo]
          "[]#{vo.name}{#{GoUtils.camel_case(vo.name)}Item}"
        else
          cmd_attr = @cmd.attributes.find { |c| c.name == a.name }
          cmd_attr ? "c.#{GoUtils.pascal_case(a.name)}" : GoUtils.go_zero_value(GoUtils.go_type(a))
        end
      end.join(", ")

      lines << "\tagg := New#{@agg.name}(#{constructor_args})"
      # Set lifecycle default status on create — from AggregateContract
      rules = HecksTemplating::AggregateContract.rules(@agg)
      if rules[:lifecycle]
        lines << "\tagg.#{GoUtils.pascal_case(rules[:lifecycle][:field])} = \"#{rules[:lifecycle][:default]}\""
      end
      lines << "\tif err := agg.Validate(); err != nil {"
      lines << "\t\treturn nil, nil, err"
      lines << "\t}"
      lines << "\tif err := repo.Save(agg); err != nil {"
      lines << "\t\treturn nil, nil, err"
      lines << "\t}"
      lines << "\tevent := #{@go_event_name}{"
      lines << "\t\tAggregateID: agg.ID,"
      @cmd.attributes.each do |a|
        lines << "\t\t#{GoUtils.pascal_case(a.name)}: c.#{GoUtils.pascal_case(a.name)},"
      end
      lines << "\t\tOccurredAt: time.Now(),"
      lines << "\t}"
      lines << "\treturn agg, &event, nil"
      lines
    end

    def update_body
      lines = []
      lines << "\texisting, err := repo.Find(c.#{GoUtils.pascal_case(@self_id.name)})"
      lines << "\tif err != nil {"
      lines << "\t\treturn nil, nil, err"
      lines << "\t}"
      lines << "\tif existing == nil {"
      lines << "\t\treturn nil, nil, fmt.Errorf(\"#{@agg.name} not found: %s\", c.#{GoUtils.pascal_case(@self_id.name)})"
      lines << "\t}"
      # Apply changes — only set fields that exist on the aggregate
      agg_attr_names = @agg.attributes.map { |a| a.name.to_s }
      @cmd.attributes.each do |a|
        next if a == @self_id
        if agg_attr_names.include?(a.name.to_s)
          lines << "\texisting.#{GoUtils.pascal_case(a.name)} = c.#{GoUtils.pascal_case(a.name)}"
        end
      end
      # Apply lifecycle transition — from AggregateContract
      rules = HecksTemplating::AggregateContract.rules(@agg)
      if rules[:lifecycle]
        transition = rules[:lifecycle][:transitions].find { |t| t[:command] == @cmd.name }
        if transition
          field = GoUtils.pascal_case(rules[:lifecycle][:field])
          from = transition[:from]
          if from
            from_list = from.is_a?(Array) ? from : [from]
            from_check = from_list.map { |f| "existing.#{field} != \"#{f}\"" }.join(" && ")
            lines << "\tif #{from_check} {"
            lines << "\t\treturn nil, nil, fmt.Errorf(\"cannot #{@cmd.name}: #{@agg.name} is in %s state\", existing.#{field})"
            lines << "\t}"
          end
          lines << "\texisting.#{field} = \"#{transition[:target]}\""
        end
      end
      lines << "\texisting.UpdatedAt = time.Now()"
      lines << "\tif err := existing.Validate(); err != nil {"
      lines << "\t\treturn nil, nil, err"
      lines << "\t}"
      lines << "\tif err := repo.Save(existing); err != nil {"
      lines << "\t\treturn nil, nil, err"
      lines << "\t}"
      lines << "\tevent := #{@go_event_name}{"
      lines << "\t\tAggregateID: existing.ID,"
      @cmd.attributes.each do |a|
        lines << "\t\t#{GoUtils.pascal_case(a.name)}: c.#{GoUtils.pascal_case(a.name)},"
      end
      lines << "\t\tOccurredAt: time.Now(),"
      lines << "\t}"
      lines << "\treturn existing, &event, nil"
      lines
    end
  end
end
