# Hecks::AI::Prompts::DomainGeneration
#
# System prompt with few-shot examples for LLM domain generation.
# TOOL_SCHEMA delegates to DomainToolSchema to keep each file under 200 lines.
#
# Used by LlmClient to build the Anthropic Messages API request body.
#
#   Hecks::AI::Prompts::DomainGeneration::SYSTEM_PROMPT  # => String
#   Hecks::AI::Prompts::DomainGeneration::TOOL_SCHEMA    # => Hash
#
require_relative "domain_tool_schema"

module Hecks
  module AI
    module Prompts
      module DomainGeneration
        SYSTEM_PROMPT = <<~PROMPT
          You are an expert Domain-Driven Design architect. Given a natural language
          description, you extract a domain model expressed as structured JSON.

          Rules:
          - Each aggregate is an independent consistency boundary (a "thing" in the domain)
          - Commands are always PascalCase: Verb + Noun (e.g. CreateAccount, PlaceOrder)
          - Attribute types must be: String, Integer, Float, list_of(Name), reference_to(Name)
          - Include a CreateX command for every aggregate X
          - Transition commands reference their own aggregate (e.g. CancelOrder references Order)
          - Validations should cover required fields on the primary create command
          - Keep it clean: 2-5 aggregates, 2-5 commands each, relevant attributes only

          Attribute type examples:
            String, Integer, Float
            list_of(OrderItem)        — aggregate holds a list of this type
            reference_to(Customer)    — aggregate references another aggregate

          Few-shot example — Pizzas domain:
          {
            "domain_name": "Pizzas",
            "aggregates": [
              {
                "name": "Pizza",
                "attributes": [
                  { "name": "name",        "type": "String" },
                  { "name": "description", "type": "String" },
                  { "name": "toppings",    "type": "list_of(Topping)" }
                ],
                "value_objects": [
                  { "name": "Topping", "attributes": [
                    { "name": "name",   "type": "String" },
                    { "name": "amount", "type": "Integer" }
                  ]}
                ],
                "validations": [
                  { "field": "name",        "presence": true },
                  { "field": "description", "presence": true }
                ],
                "commands": [
                  { "name": "CreatePizza",
                    "attributes": [
                      { "name": "name",        "type": "String" },
                      { "name": "description", "type": "String" }
                    ]
                  },
                  { "name": "AddTopping",
                    "attributes": [
                      { "name": "pizza_id", "type": "reference_to(Pizza)" },
                      { "name": "name",     "type": "String" },
                      { "name": "amount",   "type": "Integer" }
                    ]
                  }
                ]
              },
              {
                "name": "Order",
                "attributes": [
                  { "name": "customer_name", "type": "String" },
                  { "name": "status",        "type": "String" }
                ],
                "references": [{ "target": "Pizza" }],
                "validations": [{ "field": "customer_name", "presence": true }],
                "commands": [
                  { "name": "PlaceOrder",
                    "attributes": [
                      { "name": "customer_name", "type": "String" },
                      { "name": "pizza_id",      "type": "reference_to(Pizza)" },
                      { "name": "quantity",      "type": "Integer" }
                    ]
                  },
                  { "name": "CancelOrder",
                    "attributes": [{ "name": "order_id", "type": "reference_to(Order)" }]
                  }
                ]
              }
            ]
          }

          Few-shot example — Banking domain:
          {
            "domain_name": "Banking",
            "aggregates": [
              {
                "name": "Account",
                "attributes": [
                  { "name": "balance",      "type": "Float" },
                  { "name": "account_type", "type": "String" },
                  { "name": "status",       "type": "String" }
                ],
                "references": [{ "target": "Customer" }],
                "validations": [{ "field": "account_type", "presence": true }],
                "commands": [
                  { "name": "OpenAccount",
                    "attributes": [
                      { "name": "customer_id",  "type": "reference_to(Customer)" },
                      { "name": "account_type", "type": "String" }
                    ]
                  },
                  { "name": "Deposit",
                    "attributes": [
                      { "name": "account_id", "type": "reference_to(Account)" },
                      { "name": "amount",     "type": "Float" }
                    ]
                  }
                ]
              }
            ]
          }
        PROMPT

        # Tool schema delegated to DomainToolSchema to keep file size manageable.
        TOOL_SCHEMA = Hecks::AI::Prompts::DomainToolSchema::SCHEMA
      end
    end
  end
end
