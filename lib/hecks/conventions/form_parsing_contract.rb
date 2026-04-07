# = Hecks::Conventions::FormParsingContract
#
# Maps Go type strings to HTML form specifications. Defines how each
# type should be rendered in forms (input type), parsed from form
# submissions (parse format), and what zero values to use. Consumed
# by both Ruby and Go server generators for form handling.
#
#   Hecks::Conventions::FormParsingContract.input_type("int64")    # => "number"
#   Hecks::Conventions::FormParsingContract.parse_format("int64")  # => "%d"
#   Hecks::Conventions::FormParsingContract.spec("time.Time")      # => { input: "date", ... }
#
module Hecks::Conventions
  # Hecks::Conventions::FormParsingContract
  #
  # Maps Go types to HTML input specs and parsing code for both Ruby and Go server generators.
  #
  module FormParsingContract
    SPECS = {
      "int64"          => { input: "number", parse: :sscanf, fmt: "%d", step: false },
      "float64"        => { input: "number", parse: :sscanf, fmt: "%f", step: true },
      "bool"           => { input: "checkbox", parse: :bool, fmt: nil, step: false },
      "time.Time"      => { input: "date", parse: :time, fmt: "2006-01-02", step: false },
      "string"         => { input: "text", parse: :string, fmt: nil, step: false },
      "json.RawMessage" => { input: "textarea", parse: :string, fmt: nil, step: false },
    }.freeze

    def self.spec(go_type)
      SPECS[go_type] || SPECS["string"]
    end

    def self.input_type(go_type)
      spec(go_type)[:input]
    end

    def self.parse_format(go_type)
      spec(go_type)[:fmt]
    end

    def self.step?(go_type)
      spec(go_type)[:step]
    end

    # Generate Go form-parsing code for a field.
    #
    # @param field_name [String] the HTML form field name (snake_case)
    # @param go_field [String] the Go struct field name (PascalCase)
    # @param go_type [String] the Go type string
    # @return [String] a line of Go code that parses the form value
    def self.go_parse_line(field_name, go_field, go_type)
      s = spec(go_type)
      case s[:parse]
      when :sscanf
        "if v := r.FormValue(\"#{field_name}\"); v != \"\" { fmt.Sscanf(v, \"#{s[:fmt]}\", &cmd.#{go_field}) }"
      when :time
        "if v := r.FormValue(\"#{field_name}\"); v != \"\" { cmd.#{go_field}, _ = time.Parse(\"#{s[:fmt]}\", v) }"
      when :bool
        "cmd.#{go_field} = r.FormValue(\"#{field_name}\") == \"true\""
      else
        "cmd.#{go_field} = r.FormValue(\"#{field_name}\")"
      end
    end

    # Generate Ruby form-parsing expression for a field.
    #
    # @param field_name [String] the form field name
    # @param ruby_type [String] the Ruby type string (e.g., "Integer")
    # @return [String] a Ruby expression that coerces the form value
    def self.ruby_coerce(field_name, ruby_type)
      case ruby_type
      when /Integer/ then "params[\"#{field_name}\"].to_i"
      when /Float/   then "params[\"#{field_name}\"].to_f"
      when /Date/    then "Date.parse(params[\"#{field_name}\"])"
      else "params[\"#{field_name}\"]"
      end
    end
  end
end
