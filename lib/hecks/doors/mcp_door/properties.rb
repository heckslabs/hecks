require_relative "../../../hecks"

module Hecks
  module Doors
    module McpDoor
      # The input-schema properties the MCP door's tools share.
      module Properties
        SUMMARY_PROPERTY = {
          type:        "string",
          description: "One line: why this call is happening. Required — it is what makes the audit trail legible later."
        }.freeze

        DOMAIN_PROPERTY = {
          type:        "string",
          description: "The domain directory, containing a .hecksagon (e.g. \"examples/banking\"). The `domains` tool " \
                       "lists what's available."
        }.freeze

        ARGS_PROPERTY = {
          type:        "object",
          description: "The command/query's declared arguments, nested value-object literals included " \
                       "(e.g. {\"reference\":{\"value\":\"BUG#1\"}})."
        }.freeze

        SOURCE_PROPERTY = {
          type:        "string",
          enum:        Hecks::Storehouse::SOURCE_TAGS,
          description: "Optional: who is calling, for the audit log `follow` reads back."
        }.freeze

        ROLE_PROPERTY = {
          type:        "string",
          description: "Bind a caller identity for the call's duration, so a role-gated command's authorization is " \
                       "checked rather than merely documented. Required by `dispatch` for any command that declares a " \
                       "role — omitting it refuses the call rather than running it unchecked. Also required if " \
                       "`actor_id` is given."
        }.freeze

        ACTOR_ID_PROPERTY = {
          type:        "string",
          description: "Optional, alongside `role`: WHO holds that role — once the domain attaches Governance, checked " \
                       "against a real Governance::RoleAssignment instead of a bare string match. Requires `role`."
        }.freeze
      end
    end
  end
end
