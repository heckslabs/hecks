# GoHecks::ErrorsGenerator
#
# Generates Go error types matching the hecks error hierarchy.
# All errors implement error interface and have JSON serialization.
#
#   ErrorsGenerator.new(package: "domain").generate
#
module GoHecks
  class ErrorsGenerator
    def initialize(package:)
      @package = package
    end

    def generate
      b = GoCodeBuilder.new(@package)
      b.imports('"encoding/json"')

      b.struct("ValidationError") do |s|
        s.field("Field", "string", json: "field")
        s.field("Message", "string", json: "message")
        s.field("Rule", "string", json: "rule,omitempty")
      end
      b.one_liner("ValidationError", "Error", "string", "return e.Message")
      b.blank
      b.receiver("ValidationError", "AsJSON", "[]byte") do |m|
        m.line("b, _ := json.Marshal(e)")
        m.line("return b")
      end
      b.blank

      b.struct("GuardRejected") do |s|
        s.field("Command", "string", json: "command")
        s.field("Aggregate", "string", json: "aggregate,omitempty")
        s.field("Message", "string", json: "message")
      end
      b.one_liner("GuardRejected", "Error", "string", "return e.Message")
      b.blank

      b.struct("GateAccessDenied") do |s|
        s.field("Role", "string", json: "role")
        s.field("Action", "string", json: "action")
        s.field("Message", "string", json: "message")
      end
      b.one_liner("GateAccessDenied", "Error", "string", "return e.Message")

      b.to_s
    end
  end
end
