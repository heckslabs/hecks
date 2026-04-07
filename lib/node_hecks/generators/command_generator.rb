# NodeHecks::CommandGenerator
#
# Generates TypeScript command functions that return typed event objects.
# Create commands build a new aggregate; update commands modify an existing one.
#
#   gen = CommandGenerator.new(command, aggregate: agg, event: evt)
#   gen.generate  # => TypeScript source string with attrs interface, event interface, and function
#
module NodeHecks
  class CommandGenerator
    include NodeUtils

    def initialize(command, aggregate:, event:)
      @cmd = command
      @agg = aggregate
      @event = event
      @self_id = HecksTemplating::CommandContract.find_self_ref(@cmd.attributes, @agg.name)
      @is_create = @self_id.nil?
    end

    def generate
      slug = NodeUtils.snake_case(@agg.name)
      lines = []
      lines << NodeUtils.ts_import(@agg.name, "../aggregates/#{slug}")
      lines << NodeUtils.ts_import("#{@agg.name}Repository", "../repositories/#{slug}_repository")
      lines << NodeUtils.ts_import("randomUUID", "crypto")
      lines << ""
      lines.concat(attrs_interface)
      lines << ""
      lines.concat(event_interface)
      lines << ""
      lines.concat(command_function)
      NodeUtils.join_lines(lines)
    end

    private

    def attrs_interface
      fields = @cmd.attributes.map { |attr| "#{NodeUtils.camel_case(attr.name)}: #{NodeUtils.ts_type(attr)};" }
      NodeUtils.ts_interface("#{@cmd.name}Attrs", fields)
    end

    def event_interface
      fields = ["type: \"#{@event.name}\";", "aggregateId: string;"]
      @cmd.attributes.each { |attr| fields << "#{NodeUtils.camel_case(attr.name)}: #{NodeUtils.ts_type(attr)};" }
      fields << "occurredAt: string;"
      NodeUtils.ts_interface(@event.name, fields)
    end

    def command_function
      fn_name = NodeUtils.camel_case(@cmd.name)
      lines = []
      if @is_create
        lines << "export function #{fn_name}(attrs: #{@cmd.name}Attrs, repo: #{@agg.name}Repository): #{@event.name} {"
        lines.concat(create_body)
      else
        lines << "export function #{fn_name}(attrs: #{@cmd.name}Attrs, repo: #{@agg.name}Repository): #{@event.name} {"
        lines.concat(update_body)
      end
      lines << "}"
      lines
    end

    def create_body
      agg_attrs = @agg.attributes.reject { |attr| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(attr.name.to_s) }
      lines = []
      lines << "  const now = new Date().toISOString();"
      lines << "  const #{NodeUtils.camel_case(@agg.name)}: #{@agg.name} = {"
      lines << "    id: randomUUID(),"
      agg_attrs.each do |agg_attr|
        cmd_attr = @cmd.attributes.find { |cmd_a| cmd_a.name == agg_attr.name }
        if cmd_attr
          lines << "    #{NodeUtils.camel_case(agg_attr.name)}: attrs.#{NodeUtils.camel_case(agg_attr.name)},"
        else
          lines << "    #{NodeUtils.camel_case(agg_attr.name)}: #{ts_default(agg_attr)},"
        end
      end
      lines << "    createdAt: now,"
      lines << "    updatedAt: now,"
      lines << "  };"
      lines << "  repo.save(#{NodeUtils.camel_case(@agg.name)});"
      lines.concat(event_return_block("#{NodeUtils.camel_case(@agg.name)}.id"))
      lines
    end

    def update_body
      lines = []
      lines << "  const existing = repo.find(attrs.#{NodeUtils.camel_case(@self_id.name)});"
      lines << "  if (!existing) { throw new Error(\"#{@agg.name} not found\"); }"
      lines << "  const now = new Date().toISOString();"
      agg_attr_names = @agg.attributes.map { |attr| attr.name.to_s }
      @cmd.attributes.each do |cmd_attr|
        next if cmd_attr == @self_id
        if agg_attr_names.include?(cmd_attr.name.to_s)
          lines << "  existing.#{NodeUtils.camel_case(cmd_attr.name)} = attrs.#{NodeUtils.camel_case(cmd_attr.name)};"
        end
      end
      lines << "  existing.updatedAt = now;"
      lines << "  repo.save(existing);"
      lines.concat(event_return_block("existing.id"))
      lines
    end

    def event_return_block(id_expr)
      pairs = [
        ["type", "\"#{@event.name}\""],
        ["aggregateId", id_expr],
      ]
      @cmd.attributes.each { |attr| pairs << [NodeUtils.camel_case(attr.name), "attrs.#{NodeUtils.camel_case(attr.name)}"] }
      pairs << ["occurredAt", "now"]
      NodeUtils.ts_return_object("  ", pairs)
    end

    def ts_default(attr)
      if attr.list?
        "[]"
      else
        case NodeUtils.ts_type(attr)
        when "string"  then '""'
        when "number"  then "0"
        when "boolean" then "false"
        else '""'
        end
      end
    end
  end
end
