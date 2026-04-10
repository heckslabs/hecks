# Hecks::DomainPresentation
#
# Compiled from nursery/hecks/domain_presentation.bluebook.
# Each domain concept knows how to express itself as a panel.
# The UI reads render_mode, color, icon — never hardcodes them.
#
#   Hecks::DomainPresentation.for(:command)
#   # => { render_mode: "form", color: "#58a6ff", icon: "C", content_shape: "list" }
#
#   Hecks::DomainPresentation.express(aggregate)
#   # => [{ concept_type: :attribute, name: "status", ... }, ...]
#
module Hecks
  module DomainPresentation
    EXPRESSIONS = {
      attribute:    { render_mode: "tree_node",     color: "#7ee787", icon: "A", content_shape: "key_value_pairs" },
      command:      { render_mode: "form",          color: "#58a6ff", icon: "C", content_shape: "list" },
      event:        { render_mode: "log_entry",     color: "#d2a8ff", icon: "E", content_shape: "stream" },
      lifecycle:    { render_mode: "state_machine", color: "#bc8cff", icon: "L", content_shape: "graph" },
      policy:       { render_mode: "wire",          color: "#f85149", icon: "P", content_shape: "key_value_pairs" },
      value_object: { render_mode: "tree_node",     color: "#f0883e", icon: "V", content_shape: "list" },
      reference:    { render_mode: "tree_node",     color: "#f0883e", icon: "R", content_shape: "key_value_pairs" },
      given:        { render_mode: "detail",        color: "#d29922", icon: "G", content_shape: "key_value_pairs" },
      mutation:     { render_mode: "detail",        color: "#79c0ff", icon: "M", content_shape: "key_value_pairs" },
    }.freeze

    def self.for(concept_type)
      EXPRESSIONS.fetch(concept_type)
    end

    def self.all
      EXPRESSIONS
    end

    def self.express(aggregate)
      sections = []
      aggregate.attributes.each { |a| sections << section(:attribute, a.name) }
      aggregate.value_objects.each { |v| sections << section(:value_object, v.name) }
      refs = aggregate.respond_to?(:references) ? Array(aggregate.references) : []
      refs.each { |r| sections << section(:reference, r.respond_to?(:type) ? r.type.to_s : r.name.to_s) }
      aggregate.commands.each do |c|
        sections << section(:command, c.name)
        c.givens.each { |g| sections << section(:given, g.message) }
        c.mutations.each { |m| sections << section(:mutation, "#{m.field}") }
      end
      evts = aggregate.respond_to?(:events) ? Array(aggregate.events) : []
      evts.each { |e| sections << section(:event, e.respond_to?(:name) ? e.name : e.to_s) }
      if aggregate.respond_to?(:lifecycle) && aggregate.lifecycle
        sections << section(:lifecycle, aggregate.lifecycle.field.to_s)
      end
      sections
    end

    def self.section(concept_type, name)
      expr = EXPRESSIONS.fetch(concept_type)
      {
        concept_type: concept_type,
        name: name,
        render_mode: expr[:render_mode],
        color: expr[:color],
        icon: expr[:icon],
        content_shape: expr[:content_shape]
      }
    end
  end
end
