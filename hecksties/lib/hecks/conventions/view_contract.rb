# = Hecks::Conventions::ViewContract
#
# Shared data shape contracts for the web explorer views. Each contract
# defines the fields, types, and nested structs a template expects.
# Generators for Go and Ruby both consume these contracts, ensuring
# struct fields and template bindings never drift apart.
#
#   contract = Hecks::Conventions::ViewContract::INDEX
#   contract[:fields]  # => [{name: :aggregate_name, type: :string}, ...]
#   Hecks::Conventions::ViewContract.go_name(:short_id)  # => "ShortId"
#
module Hecks::Conventions
  module ViewContract
    # Maps a snake_case field name to a Go PascalCase name.
    # Centralizes the naming rule so templates and structs agree.
    def self.go_name(field)
      Hecks::Utils.sanitize_constant(field)
    end

    # Display conventions shared by all targets.
    SHORT_ID_LENGTH = 8

    # Ruby expression to truncate an ID for display.
    def self.ruby_short_id(id_expr)
      "#{id_expr}[0..#{SHORT_ID_LENGTH - 1}] + \"...\""
    end

    # Go expression to truncate an ID for display.
    def self.go_short_id(id_var)
      "sid := #{id_var}; if len(sid)>#{SHORT_ID_LENGTH} { sid=sid[:#{SHORT_ID_LENGTH}]+\"...\" }"
    end

    # All contract constants, keyed by template name.
    def self.all
      { layout: LAYOUT, home: HOME, index: INDEX,
        show: SHOW, form: FORM, config: CONFIG }
    end

    # Go type string for a contract field type.
    GO_TYPES = { string: "string", int: "int", bool: "bool",
                 html: "template.HTML", string_list: "[]string" }.freeze

    # Struct types defined once in renderer.go — never get an aggregate prefix.
    SHARED_TYPES = %i[row_action form_field form_option nav_item].freeze

    # Generate a Go struct definition from a contract's struct fields.
    # Returns a single-line struct: `type Name struct { Field1 string; Field2 int }`
    def self.go_struct(name, fields, prefix: "")
      parts = fields.map do |f|
        go_field = go_name(f[:name])
        go_type = if f[:type] == :list
                    item = f[:item_type]
                    type_prefix = SHARED_TYPES.include?(item) ? "" : prefix
                    "[]#{type_prefix}#{go_name(item)}"
                  else
                    GO_TYPES[f[:type]] || "string"
                  end
        "#{go_field} #{go_type}"
      end
      "type #{prefix}#{go_name(name)} struct { #{parts.join('; ')} }"
    end

    # ERB loop variable mappings per template.
    # Keys are the ERB block variable names (from |var|);
    # values describe what they iterate and their parent collection.
    def self.loop_vars(template_name)
      LOOP_VARS[template_name] || {}
    end

    # ── Layout ──────────────────────────────────────────────
    LAYOUT = {
      name: :layout,
      fields: [
        { name: :title, type: :string },
        { name: :brand, type: :string },
        { name: :content, type: :html },
        { name: :nav_items, type: :list, item_type: :nav_item },
      ],
      structs: {
        nav_item: [
          { name: :label, type: :string },
          { name: :href, type: :string },
          { name: :group, type: :string },
        ],
      },
    }.freeze

    # ── Home ────────────────────────────────────────────────
    HOME = {
      name: :home,
      fields: [
        { name: :domain_name, type: :string },
        { name: :aggregates, type: :list, item_type: :home_agg },
      ],
      structs: {
        home_agg: [
          { name: :href, type: :string },
          { name: :name, type: :string },
          { name: :commands, type: :int },
          { name: :attributes, type: :int },
          { name: :policies, type: :int },
        ],
      },
    }.freeze

    # ── Index ───────────────────────────────────────────────
    INDEX = {
      name: :index,
      fields: [
        { name: :aggregate_name, type: :string },
        { name: :description, type: :string },
        { name: :items, type: :list, item_type: :index_item },
        { name: :columns, type: :list, item_type: :column },
        { name: :buttons, type: :list, item_type: :button },
        { name: :row_actions, type: :list, item_type: :row_action },
      ],
      structs: {
        index_item: [
          { name: :id, type: :string },
          { name: :short_id, type: :string },
          { name: :show_href, type: :string },
          { name: :cells, type: :string_list },
          { name: :row_actions, type: :list, item_type: :row_action },
        ],
        column: [
          { name: :label, type: :string },
        ],
        button: [
          { name: :label, type: :string },
          { name: :href, type: :string },
          { name: :allowed, type: :bool },
          { name: :direct, type: :bool },
          { name: :id_field, type: :string },
        ],
        row_action: [
          { name: :label, type: :string },
          { name: :href_prefix, type: :string },
          { name: :id, type: :string },
          { name: :allowed, type: :bool },
          { name: :direct, type: :bool },
          { name: :id_field, type: :string },
        ],
      },
    }.freeze

    # ── Show ────────────────────────────────────────────────
    SHOW = {
      name: :show,
      fields: [
        { name: :aggregate_name, type: :string },
        { name: :id, type: :string },
        { name: :back_href, type: :string },
        { name: :fields, type: :list, item_type: :show_field },
        { name: :buttons, type: :list, item_type: :button },
      ],
      structs: {
        show_field: [
          { name: :label, type: :string },
          { name: :value, type: :string },
          { name: :type, type: :string },
          { name: :items, type: :string_list },
          { name: :transitions, type: :string_list },
        ],
        button: [
          { name: :label, type: :string },
          { name: :href, type: :string },
          { name: :allowed, type: :bool },
          { name: :direct, type: :bool },
          { name: :id_field, type: :string },
        ],
      },
    }.freeze

    # ── Form ────────────────────────────────────────────────
    FORM = {
      name: :form,
      fields: [
        { name: :command_name, type: :string },
        { name: :action, type: :string },
        { name: :error_message, type: :string },
        { name: :fields, type: :list, item_type: :form_field },
      ],
      structs: {
        form_field: [
          { name: :type, type: :string },
          { name: :name, type: :string },
          { name: :label, type: :string },
          { name: :input_type, type: :string },
          { name: :value, type: :string },
          { name: :required, type: :bool },
          { name: :step, type: :bool },
          { name: :error, type: :string },
          { name: :options, type: :list, item_type: :form_option },
        ],
        form_option: [
          { name: :value, type: :string },
          { name: :label, type: :string },
          { name: :selected, type: :bool },
        ],
      },
    }.freeze

    # ── Config ──────────────────────────────────────────────
    CONFIG = {
      name: :config,
      fields: [
        { name: :roles, type: :string_list },
        { name: :current_role, type: :string },
        { name: :adapters, type: :string_list },
        { name: :current_adapter, type: :string },
        { name: :event_count, type: :int },
        { name: :booted_at, type: :string },
        { name: :policies, type: :string_list },
        { name: :aggregates, type: :list, item_type: :config_agg },
        { name: :structure_diagram, type: :html },
        { name: :behavior_diagram, type: :html },
        { name: :flows_diagram, type: :html },
      ],
      structs: {
        config_agg: [
          { name: :name, type: :string },
          { name: :href, type: :string },
          { name: :count, type: :int },
          { name: :commands, type: :string },
          { name: :ports, type: :string },
        ],
      },
    }.freeze

    # ── Loop variable mappings ──────────────────────────────
    # Maps ERB block variable names to :dot (use {{ . }}) when
    # iterating a simple string list, or :struct when iterating
    # a list of structs (use {{ .Field }}).
    LOOP_VARS = {
      layout: { item: :struct, group: :skip },
      home:   { agg: :struct },
      index:  { item: :struct, col: :struct, btn: :struct,
                action: :struct, cell: :dot },
      show:   { field: :struct, btn: :struct, li: :dot },
      form:   { field: :struct, opt: :struct },
      config: { r: :dot, a: :dot, p: :dot, row: :struct },
    }.freeze
  end
end
