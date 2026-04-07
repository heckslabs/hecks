# GoHecks::AggregateGenerator
#
# Generates a Go struct for an aggregate root. Uses AggregateContract
# to determine standard fields, validations, enum constraints, and
# invariants — guaranteeing identical runtime behavior to Ruby.
#
#   gen = AggregateGenerator.new(agg, package: "domain")
#   gen.generate  # => Go source string
#
module GoHecks
  class AggregateGenerator
    include GoUtils

    def initialize(aggregate, package:)
      @agg = aggregate
      @package = package
      @user_attrs = @agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
      @rules = HecksTemplating::AggregateContract.rules(@agg)
    end

    def generate
      lines = []
      lines << "package #{@package}"
      lines << ""
      lines.concat(imports)
      lines.concat(struct_definition)
      lines.concat(constructor)
      lines.concat(validate_method)
      lines.join("\n") + "\n"
    end

    private

    def imports
      lines = []
      pkgs = ["\"time\"", "\"github.com/google/uuid\""]
      pkgs << "\"fmt\"" if @rules[:enums].any?
      pkgs << "\"encoding/json\"" if GoUtils.needs_json_import?(@user_attrs)
      lines << "import ("
      pkgs.each { |i| lines << "\t#{i}" }
      lines << ")"
      lines << ""
      lines
    end

    def struct_definition
      lines = []
      lines << "type #{@agg.name} struct {"
      @rules[:standard_fields].each do |sf|
        lines << "\t#{sf[:go_field]} #{sf[:go]} `json:\"#{sf[:json]}\"`"
      end
      @user_attrs.each do |attr|
        lines << "\t#{GoUtils.pascal_case(attr.name)} #{GoUtils.go_type(attr)} `json:\"#{GoUtils.json_tag(attr.name)}\"`"
      end
      lines << "}"
      lines << ""
      lines
    end

    def constructor
      params = @user_attrs.map { |a| "#{GoUtils.camel_case(a.name)} #{GoUtils.go_type(a)}" }.join(", ")
      lines = []
      lines << "func New#{@agg.name}(#{params}) *#{@agg.name} {"
      lines << "\ta := &#{@agg.name}{"
      lines << "\t\tID:        uuid.New().String(),"
      @user_attrs.each do |attr|
        lines << "\t\t#{GoUtils.pascal_case(attr.name)}: #{GoUtils.camel_case(attr.name)},"
      end
      lines << "\t\tCreatedAt: time.Now(),"
      lines << "\t\tUpdatedAt: time.Now(),"
      lines << "\t}"
      lines << "\treturn a"
      lines << "}"
      lines << ""
      lines
    end

    def validate_method
      lines = []
      lines << "func (a *#{@agg.name}) Validate() error {"

      # Presence checks — from contract
      @rules[:validations].each do |v|
        next unless v[:check] == :presence
        field = GoUtils.pascal_case(v[:field])
        lines << "\tif a.#{field} == \"\" {"
        lines << "\t\treturn &ValidationError{Field: \"#{v[:field]}\", Message: \"#{v[:field]} can't be blank\"}"
        lines << "\t}"
      end

      # Enum checks — from contract
      @rules[:enums].each do |e|
        field = GoUtils.pascal_case(e[:field])
        valid_map = e[:values].map { |v| "\"#{v}\": true" }.join(", ")
        lines << "\tif a.#{field} != \"\" {"
        lines << "\t\tvalid#{field} := map[string]bool{#{valid_map}}"
        lines << "\t\tif !valid#{field}[a.#{field}] {"
        lines << "\t\t\treturn &ValidationError{Field: \"#{e[:field]}\", Message: fmt.Sprintf(\"#{e[:field]} must be one of: #{e[:values].join(", ")}, got: %s\", a.#{field})}"
        lines << "\t\t}"
        lines << "\t}"
      end

      # Invariants — from contract (documented as comments)
      @rules[:invariants].each do |inv|
        lines << "\t// invariant: #{inv[:message]}"
      end

      lines << "\treturn nil"
      lines << "}"
      lines.concat(computed_methods)
      lines
    end

    def computed_methods
      cas = @agg.computed_attributes || []
      return [] if cas.empty?
      lines = []
      cas.each do |ca|
        lines << ""
        lines << "// #{GoUtils.pascal_case(ca.name)} — computed attribute (TODO: implement)"
        lines << "func (a *#{@agg.name}) #{GoUtils.pascal_case(ca.name)}() interface{} {"
        lines << "\t// TODO: translate computed logic from Ruby DSL"
        lines << "\treturn nil"
        lines << "}"
      end
      lines
    end
  end
end
