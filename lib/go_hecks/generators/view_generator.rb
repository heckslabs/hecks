# GoHecks::ViewGenerator
#
# Converts ERB templates to Go html/template syntax using ViewContract
# as a lookup table. The contract drives all field name resolution so
# Go struct fields and Go template bindings can never drift apart.
#
#   gen = GoHecks::ViewGenerator.new
#   go_template = gen.convert(:config, erb_source)
#
module GoHecks
  class ViewGenerator
    def initialize
      @contracts = HecksTemplating::ViewContract
    end

    # Convert an ERB template to Go html/template syntax.
    #
    # @param template_name [Symbol] :layout, :home, :index, :show, :form, :config
    # @param erb [String] ERB source
    # @return [String] Go template source
    def convert(template_name, erb)
      @template_name = template_name
      @contract = @contracts.all[template_name]
      @loop_vars = @contracts.loop_vars(template_name)
      @field_lookup = build_field_lookup

      go = erb.dup
      go = wrap_define(template_name, go)
      go = convert_loops(go)
      go = convert_loop_var_refs(go)
      go = convert_output_tags(go)
      go = convert_conditionals(go)
      go = convert_layout_groups(go)
      go = convert_control_tags(go)
      go = cleanup(go)
      go
    end

    private

    def gn(field)
      @contracts.go_name(field)
    end

    # Build lookup: { "field_name" => "GoName" } for all fields in contract
    def build_field_lookup
      lookup = {}
      @contract[:fields].each { |f| lookup[f[:name].to_s] = gn(f[:name]) }
      @contract[:structs]&.each do |_name, fields|
        fields.each { |f| lookup[f[:name].to_s] = gn(f[:name]) }
      end
      lookup
    end

    def wrap_define(name, go)
      if name == :layout
        "{{ define \"layout\" }}#{go}{{ end }}\n"
      else
        "{{ define \"#{name}\" }}\n#{go}{{ end }}\n"
      end
    end

    def convert_loops(go)
      # Track which ERB variables are loop iterators
      @loop_var_names = Set.new

      # items.each do |item| → {{ range .Items }}
      go.gsub!(/<% (\w+)\.each do \|(\w+)\| %>/) do
        collection, loop_var = $1, $2
        @loop_var_names << loop_var
        "{{ range .#{gn(collection)} }}"
      end

      # item[:cells].each do |cell| → {{ range .Cells }}
      go.gsub!(/<% (\w+)\[:(\w+)\]\.each do \|(\w+)\| %>/) do
        _parent_var, field, loop_var = $1, $2, $3
        @loop_var_names << loop_var
        "{{ range .#{gn(field)} }}"
      end

      go
    end

    def convert_loop_var_refs(go)
      @loop_var_names.each do |var|
        kind = @loop_vars[var.to_sym] || :dot
        next unless kind == :dot
        go.gsub!(/<%= #{Regexp.escape(var)} %>/, '{{ . }}')
      end
      go
    end

    def convert_output_tags(go)
      # items.size → {{ len .Items }}
      go.gsub!(/<%= (\w+)\.size %>/) { "{{ len .#{gn($1)} }}" }

      # Conditional selected: <%= ' selected' if r == current_role %>
      go.gsub!(/<%= ' selected' if (\w+) == (\w+) %>/) do
        "{{ if eq . $.#{gn($2)} }} selected{{ end }}"
      end

      # Conditional CSS class with hash: <%= ' btn-faded' unless btn[:allowed] %>
      go.gsub!(/<%= ' (\w[\w-]*)' unless (\w+)\[:(\w+)\] %>/) do
        "{{ if not .#{gn($3)} }} #{$1}{{ end }}"
      end

      # Inline conditional attribute: <%= ' step="any"' if field[:step] %>
      go.gsub!(/<%= '([^']*)' if (\w+)\[:(\w+)\] %>/) do
        "{{ if .#{gn($3)} }}#{$1}{{ end }}"
      end

      # Default value: <%= field[:input_type] || 'text' %>
      go.gsub!(/<%= (\w+)\[:(\w+)\] \|\| '(\w+)' %>/) do
        "{{ or .#{gn($2)} \"#{$3}\" }}"
      end

      # Hash access: <%= item[:field] %> → {{ .Field }}
      go.gsub!(/<%= (\w+)\[:(\w+)\] %>/) { "{{ .#{gn($2)} }}" }

      # Simple variable output: <%= var %> → {{ .Var }}
      go.gsub!(/<%= (\w+) %>/) { "{{ .#{gn($1)} }}" }

      go
    end

    def convert_conditionals(go)
      # if hash == symbol: <% if field[:type] == :hidden %>
      go.gsub!(/<% if (\w+)\[:(\w+)\] == :(\w+) %>/) do
        "{{ if eq .#{gn($2)} \"#{$3}\" }}"
      end

      # elsif hash == symbol
      go.gsub!(/<% elsif (\w+)\[:(\w+)\] == :(\w+) %>/) do
        "{{ else if eq .#{gn($2)} \"#{$3}\" }}"
      end

      # if hash && hash > 0
      go.gsub!(/<% if (\w+)\[:(\w+)\] && \w+\[:(\w+)\] > 0 %>/) do
        "{{ if gt .#{gn($2)} 0 }}"
      end

      # defined? check
      go.gsub!(/<% if defined\?\((\w+)\) && (\w+) && !(\w+)\.empty\? %>/) do
        "{{ if .#{gn($1)} }}"
      end

      # collection.any?
      go.gsub!(/<% if (\w+)\.any\? %>/) { "{{ if .#{gn($1)} }}" }

      # collection.empty?
      go.gsub!(/<% if (\w+)\.empty\? %>/) { "{{ if not .#{gn($1)} }}" }

      # if hash field truthy
      go.gsub!(/<% if (\w+)\[:(\w+)\] %>/) { "{{ if .#{gn($2)} }}" }

      # unless hash field
      go.gsub!(/<% unless (\w+)\[:(\w+)\] %>/) { "{{ if not .#{gn($2)} }}" }

      # if simple var
      go.gsub!(/<% if (\w+) %>/) { "{{ if .#{gn($1)} }}" }

      # unless simple var
      go.gsub!(/<% unless (\w+) %>/) { "{{ if not .#{gn($1)} }}" }

      # else
      go.gsub!(/<% else %>/, '{{ else }}')

      go
    end

    def convert_layout_groups(go)
      go.gsub!(/<% group = item\[:group\].*%>/, '')
      go.gsub!(/<% if group && group != last_group %>/, '{{ if and .Group (ne .Group $lastGroup) }}')
      go.gsub!(/<% last_group = group %>/, '{{ $lastGroup = .Group }}')
      go.gsub!(/<% last_group = nil %>/, '{{ $lastGroup := "" }}')
      go
    end

    def convert_control_tags(go)
      go.gsub!(/<% end %>/, '{{ end }}')
      go.gsub!(/<% next.*%>/, '')

      # Remove unconverted ERB blocks with their matching end tags
      lines = go.lines
      skip_depth = 0
      cleaned = []
      lines.each do |line|
        if line =~ /<%[^=].*%>/ && skip_depth == 0
          skip_depth = 1
        elsif skip_depth > 0
          skip_depth += 1 if line =~ /\{\{ (?:range|if) /
          if line.strip == '{{ end }}'
            skip_depth -= 1
            next if skip_depth == 0
          end
          next if skip_depth > 0
        end
        cleaned << line unless line =~ /<%.*%>/
      end
      cleaned.join
    end

    def cleanup(go)
      go.gsub!(/<%= .+? %>/, '')
      go.gsub!(/\n{3,}/, "\n\n")
      go
    end
  end
end
