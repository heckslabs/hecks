# Hecks::AI::Prompts::DomainToolSchema
#
# Anthropic tool_use schema for the define_domain tool. Defines the JSON
# structure the LLM must return when generating a domain model.
#
# Separated from DomainGeneration to keep file sizes within limits.
#
#   Hecks::AI::Prompts::DomainToolSchema::SCHEMA  # => Hash
#
module Hecks
  module AI
    module Prompts
      module DomainToolSchema
        ATTR_ITEM = {
          type: "object",
          properties: {
            name: { type: "string" },
            type: { type: "string" }
          }
        }.freeze

        NAMED_ATTRS_ITEM = {
          type: "object",
          properties: {
            name: { type: "string" },
            attributes: { type: "array", items: ATTR_ITEM }
          }
        }.freeze

        SCHEMA = {
          name: "define_domain",
          description: "Define a domain model as structured JSON for the Hecks compiler",
          input_schema: {
            type: "object",
            required: ["domain_name", "aggregates"],
            properties: {
              domain_name: { type: "string", description: "PascalCase domain name (e.g. Banking)" },
              aggregates: {
                type: "array",
                items: {
                  type: "object",
                  required: ["name", "commands"],
                  properties: {
                    name:         { type: "string" },
                    attributes:   { type: "array", items: ATTR_ITEM },
                    references:   { type: "array", items: { type: "object", properties: { target: { type: "string" } } } },
                    value_objects: { type: "array", items: NAMED_ATTRS_ITEM },
                    entities:     { type: "array", items: NAMED_ATTRS_ITEM },
                    validations:  {
                      type: "array",
                      items: {
                        type: "object",
                        properties: {
                          field:    { type: "string" },
                          presence: { type: "boolean" }
                        }
                      }
                    },
                    policies: {
                      type: "array",
                      items: {
                        type: "object",
                        properties: {
                          name:     { type: "string" },
                          on_event: { type: "string" },
                          trigger:  { type: "string" }
                        }
                      }
                    },
                    commands: {
                      type: "array",
                      items: {
                        type: "object",
                        required: ["name"],
                        properties: {
                          name:       { type: "string" },
                          attributes: { type: "array", items: ATTR_ITEM }
                        }
                      }
                    },
                    lifecycle: {
                      type: "object",
                      properties: {
                        field:   { type: "string" },
                        default: { type: "string" },
                        transitions: {
                          type: "array",
                          items: {
                            type: "object",
                            properties: {
                              command: { type: "string" },
                              target:  { type: "string" }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }.freeze
      end
    end
  end
end
