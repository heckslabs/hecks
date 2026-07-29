#!/usr/bin/env ruby
# Replay a real bluebook's IR as dispatches into the meta-domain, then
# reconstruct the IR from what the meta-domain stored and diff it against the
# source. EVERY category, or the round trip proves nothing — a replay that
# silently drops policies and process managers reports zero refusals and reads
# like success. That is exactly what the first version of this script did.
#
#   ruby -Ilib experiment/replay.rb <canonicalised-ir.json>
#
# Three IR shapes have no bluebook equivalent and are NORMALISED on the way in:
#   a mutation's `fields`         is an OPEN MAP     -> one Change row per entry
#   a value object                holds NESTED LISTS -> its own root (Shape)
#   a saga's handlers/dispatches  nest three deep    -> Saga / Leg / Send
# The reconstruction denormalises them back; the diff says whether that round
# trip is lossless.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hecksagain"
require "json"

ir_path = ARGV.shift or abort "usage: replay.rb <canonicalised-ir.json>"
source  = JSON.parse(File.read(ir_path))
chapter = source.fetch(source.keys.first)

runtime  = Hecks.boot(File.expand_path("../experiment", __dir__))
refusals = []
v = ->(x) { { value: x.to_s } }

def try(refusals, label)
  yield
rescue StandardError => e
  refusals << "#{label}: #{e.message}"
end

chapter_id = chapter.fetch("name")

try(refusals, "Chapter.Declare") do
  runtime.dispatch("Meta::Chapter.Declare", name: v[chapter_id],
                   vision: v[chapter["vision"]], classification: v[chapter["classification"]])
end

chapter.fetch("canonical_form", []).each do |rule|
  try(refusals, "Chapter.Normalise") do
    runtime.dispatch("Meta::Chapter.Normalise", name: v[chapter_id],
                     strategy: v[rule["strategy"]], source_token: v[rule["source_token"]],
                     replacement: v[rule["replacement"]], boundary: v[rule["boundary"]],
                     position: v[rule["position"]])
  end
end

chapter.fetch("policies", []).each do |policy|
  try(refusals, "Reaction.Declare #{policy['name']}") do
    runtime.dispatch("Meta::Reaction.Declare", id: "#{chapter_id}.#{policy['name']}",
                     chapter_id: v[chapter_id], name: v[policy["name"]],
                     watches: v[policy["on_event"]], fires: v[policy["trigger_command"]],
                     reaches: v[policy["target_domain"]])
  end
end

chapter.fetch("read_models", []).each do |model|
  model_id = "#{chapter_id}.#{model['name']}"
  try(refusals, "Projection.Declare #{model_id}") do
    runtime.dispatch("Meta::Projection.Declare", id: model_id, chapter_id: v[chapter_id],
                     name: v[model["name"]], purpose: v[model["description"]],
                     query_name: v[model["query_name"]], ref_name: v[model["reference_name"]],
                     ref_target: v[model["reference_target"]])
  end
  model.fetch("aggregate_heads", []).each do |head|
    try(refusals, "Projection.Gather #{model_id}") do
      runtime.dispatch("Meta::Projection.Gather", id: model_id,
                       aggregate: v[head["aggregate"]], as: v[head["as"]], many: v[head["many"]])
    end
  end
end

chapter.fetch("process_managers", []).each do |saga|
  saga_id = "#{chapter_id}.#{saga['name']}"
  try(refusals, "Saga.Declare #{saga_id}") do
    runtime.dispatch("Meta::Saga.Declare", id: saga_id, chapter_id: v[chapter_id],
                     name: v[saga["name"]], correlate: v[saga["correlates_by"]],
                     starts: v[saga["starts_on"]], ends: v[saga["ends_on"]])
  end
  saga.fetch("states", []).each do |state|
    try(refusals, "Saga.State #{saga_id}") { runtime.dispatch("Meta::Saga.State", id: saga_id, name: v[state]) }
  end
  saga.fetch("handlers", []).each_with_index do |leg, index|
    leg_id = "#{saga_id}##{index}"
    try(refusals, "Leg.Declare #{leg_id}") do
      runtime.dispatch("Meta::Leg.Declare", id: leg_id, saga_id: v[saga["name"]],
                       saga: v[saga["name"]], answers: v[leg["event_type"]],
                       from_state: v[leg["from_state"]], to_state: v[leg["to_state"]])
    end
    leg.fetch("dispatches", []).each_with_index do |send, position|
      send_id = "#{leg_id}.#{position}"
      try(refusals, "Send.Declare #{send_id}") do
        runtime.dispatch("Meta::Send.Declare", id: send_id, leg_id: v[leg_id],
                         leg: v[leg_id], verb: v[send["command_name"]])
      end
      Array(send["with"]).each do |key, value|
        try(refusals, "Send.Bind #{send_id}") do
          runtime.dispatch("Meta::Send.Bind", id: send_id, key: v[key], value: v[value])
        end
      end
    end
  end
end

declare_asks = lambda do |holder, owner, prefix|
  holder.fetch("queries", []).each do |ask|
    ask_id = "#{prefix}.#{ask['name']}"
    order  = ask["order_by"] || {}
    try(refusals, "Ask.Declare #{ask_id}") do
      runtime.dispatch("Meta::Ask.Declare", id: ask_id, root_id: v[owner],
                       name: v[ask["name"]], purpose: v[ask["description"]],
                       order_field: v[order["field"]], order_way: v[order["direction"]],
                       ceiling: v[(ask["limit"] || {})["value"]])
    end
    ask.fetch("wheres", []).each do |clause|
      try(refusals, "Ask.Filter #{ask_id}") do
        runtime.dispatch("Meta::Ask.Filter", id: ask_id, field: v[clause["field"]],
                         op: v[clause["op"]], value: v[clause["value"]])
      end
    end
    ask.fetch("attributes", []).each do |a|
      try(refusals, "Ask.Argument #{ask_id}") do
        runtime.dispatch("Meta::Ask.Argument", id: ask_id, name: v[a["name"]], type: v[a["type"]],
                         list: v[a["list"]], default: v[JSON.generate(a["default"])])
      end
    end
  end
end

declare_verbs = lambda do |holder, owner, prefix|
  holder.fetch("commands", []).each do |command|
    verb_id = "#{prefix}.#{command['name']}"

    try(refusals, "Verb.Declare #{verb_id}") do
      runtime.dispatch("Meta::Verb.Declare", id: verb_id, root_id: v[owner],
                       name: v[command["name"]], role: v[command["role"]], goal: v[command["goal"]])
    end

    command.fetch("attributes", []).each do |a|
      try(refusals, "Verb.Argument #{verb_id}.#{a['name']}") do
        runtime.dispatch("Meta::Verb.Argument", id: verb_id, name: v[a["name"]], type: v[a["type"]],
                         list: v[a["list"]], default: v[JSON.generate(a["default"])])
      end
    end

    command.fetch("givens", []).each do |g|
      try(refusals, "Verb.Rule #{verb_id}") do
        runtime.dispatch("Meta::Verb.Rule", id: verb_id,
                         description: v[g["description"]], canonical: v[g["canonical"]])
      end
    end

    command.fetch("mutations", []).each do |m|
      rows = if m["fields"]
               m["fields"].map { |field, src| [field, "argument", src] }
             else
               src = m["source"] || {}
               # a literal may be an OBJECT ({value: "good"}), so carry it as
               # JSON text and parse it back rather than flattening to a string
               carried = src["kind"] == "literal" ? JSON.generate(src["value"]) : src["name"].to_s
               [["", src["kind"].to_s, carried]]
             end
      rows.each do |field, kind, src|
        try(refusals, "Verb.Change #{verb_id}.#{m['target']}") do
          runtime.dispatch("Meta::Verb.Change", id: verb_id, target: v[m["target"]],
                           op: v[m["op"]], field: v[field], kind: v[kind], source: v[src])
        end
      end
    end

    if (ref = command["references"])
      try(refusals, "Verb.ActsOn #{verb_id}") { runtime.dispatch("Meta::Verb.ActsOn", id: verb_id, root: v[ref]) }
    end
    Array(command["emits"]).each do |event|
      try(refusals, "Verb.Announce #{verb_id}") { runtime.dispatch("Meta::Verb.Announce", id: verb_id, announces: v[event]) }
    end
  end
end

chapter.fetch("aggregates").each do |aggregate|
  root_id = "#{chapter_id}::#{aggregate['name']}"

  try(refusals, "Root.Declare #{root_id}") do
    runtime.dispatch("Meta::Root.Declare", id: root_id, chapter_id: v[chapter_id],
                     name: v[aggregate["name"]], description: v[aggregate["description"]],
                     identity: v[aggregate["identified_by"]])
  end

  aggregate.fetch("attributes", []).each do |a|
    try(refusals, "Root.Attribute #{root_id}.#{a['name']}") do
      runtime.dispatch("Meta::Root.Attribute", id: root_id,
                       name: v[a["name"]], type: v[a["type"]], list: v[a["list"]])
    end
  end

  if (life = aggregate["lifecycle"])
    try(refusals, "Root.Lifecycle #{root_id}") do
      runtime.dispatch("Meta::Root.Lifecycle", id: root_id,
                       state_field: v[life["field"]], state_start: v[life["default"]])
    end
    life.fetch("transitions", []).each do |t|
      try(refusals, "Root.Transition #{root_id}") do
        runtime.dispatch("Meta::Root.Transition", id: root_id, command: v[t["command"]],
                         from_state: v[t["from_state"]], to_state: v[t["to_state"]])
      end
    end
  end

  aggregate.fetch("value_objects", []).each do |shape|
    shape_id = "#{root_id}.#{shape['name']}"
    try(refusals, "Root.Value #{shape_id}") { runtime.dispatch("Meta::Root.Value", id: root_id, name: v[shape["name"]]) }
    try(refusals, "Shape.Declare #{shape_id}") do
      runtime.dispatch("Meta::Shape.Declare", id: shape_id, root_id: v[aggregate["name"]], name: v[shape["name"]])
    end
    shape.fetch("attributes", []).each do |f|
      try(refusals, "Shape.Field #{shape_id}.#{f['name']}") do
        runtime.dispatch("Meta::Shape.Field", id: shape_id, name: v[f["name"]], type: v[f["type"]],
                         list: v[f["list"]], default: v[JSON.generate(f["default"])])
      end
    end
    shape.fetch("members", []).each_with_index do |row, mi|
      member_id = "#{shape_id}##{mi}"
      try(refusals, "Member.Declare #{member_id}") do
        runtime.dispatch("Meta::Member.Declare", id: member_id, shape_id: v[shape["name"]], shape: v[shape_id])
      end
      Array(row).each do |key, value|
        try(refusals, "Member.Pair #{member_id}") do
          runtime.dispatch("Meta::Member.Pair", id: member_id, key: v[key], value: v[value])
        end
      end
    end
    shape.fetch("invariants", []).each do |inv|
      try(refusals, "Shape.Assert #{shape_id}") do
        runtime.dispatch("Meta::Shape.Assert", id: shape_id,
                         description: v[inv["description"]], canonical: v[inv["canonical"]])
      end
    end
  end

  declare_asks.call(aggregate, aggregate["name"], root_id)
  declare_verbs.call(aggregate, aggregate["name"], root_id)

  aggregate.fetch("entities", []).each do |piece|
    piece_id = "#{root_id}.#{piece['name']}"
    owner    = "#{aggregate['name']}.#{piece['name']}"
    try(refusals, "Piece.Declare #{piece_id}") do
      runtime.dispatch("Meta::Piece.Declare", id: piece_id, root_id: v[aggregate["name"]],
                       owner: v[aggregate["name"]], name: v[piece["name"]],
                       description: v[piece["description"]], identity: v[piece["identified_by"]])
    end
    piece.fetch("attributes", []).each do |a|
      try(refusals, "Piece.Attribute #{piece_id}") do
        runtime.dispatch("Meta::Piece.Attribute", id: piece_id, name: v[a["name"]], type: v[a["type"]],
                         list: v[a["list"]], default: v[JSON.generate(a["default"])])
      end
    end
    if (life = piece["lifecycle"])
      try(refusals, "Piece.Lifecycle #{piece_id}") do
        runtime.dispatch("Meta::Piece.Lifecycle", id: piece_id,
                         state_field: v[life["field"]], state_start: v[life["default"]])
      end
      life.fetch("transitions", []).each do |tr|
        try(refusals, "Piece.Transition #{piece_id}") do
          runtime.dispatch("Meta::Piece.Transition", id: piece_id, command: v[tr["command"]],
                           from_state: v[tr["from_state"]], to_state: v[tr["to_state"]])
        end
      end
    end
    declare_asks.call(piece, owner, piece_id)
    declare_verbs.call(piece, owner, piece_id)
  end
end

stored = Hash.new { |h, k| h[k] = [] }
runtime.registry.bluebooks.each do |name, bluebook|
  bluebook.aggregates.each do |aggregate|
    runtime.registry.repository(name, aggregate).all.each do |record|
      stored[aggregate.name] << record.state.merge(__id: record.id)
    end
  end
end

# ---- denormalise back into IR shape ----------------------------------------
val    = ->(vo) { vo.nil? ? nil : vo[:value].to_s }
blank  = ->(s) { s.to_s.empty? ? nil : s.to_s }
truthy = ->(s) { s.to_s == "true" }

build_ask = lambda do |q|
  { "attributes" => Array(q[:arguments]).map { |a|
      { "default" => (a[:default].to_s.empty? ? nil : JSON.parse(a[:default].to_s)), "list" => truthy[a[:list]], "name" => a[:name], "type" => a[:type] } },
    "description" => blank[val[q[:purpose]]],
    "limit" => (blank[val[q[:ceiling]]] ? { "value" => val[q[:ceiling]] } : nil),
    "name" => val[q[:name]],
    "order_by" => (blank[val[q[:order_field]]] ? { "direction" => val[q[:order_way]], "field" => val[q[:order_field]] } : nil),
    "wheres" => Array(q[:filters]).map { |w| { "field" => w[:field], "op" => w[:op], "value" => w[:value] } } }
end

build_verb = lambda do |x|
  changes = Array(x[:changes])
  { "attributes" => Array(x[:arguments]).map { |a|
      { "default" => (a[:default].to_s.empty? ? nil : JSON.parse(a[:default].to_s)), "list" => truthy[a[:list]], "name" => a[:name], "type" => a[:type] } },
    "emits" => Array(x[:emissions]).map { |e| e[:name] },
    "givens" => Array(x[:rules]).map { |r| { "canonical" => r[:canonical], "description" => r[:description] } },
    "goal" => blank[val[x[:goal]]], "name" => val[x[:name]],
    "references" => blank[val[x[:acts_on]]], "role" => blank[val[x[:role]]],
    "mutations" => changes.group_by { |c| [c[:target], c[:op]] }.map { |(target, op), rows|
      if op == "append"
        { "fields" => rows.to_h { |r| [r[:field], r[:source]] }, "op" => op, "target" => target }
      else
        r = rows.first
        src = r[:kind] == "literal" ? { "kind" => "literal", "value" => JSON.parse(r[:source].to_s) } : { "kind" => r[:kind], "name" => r[:source] }
        { "op" => op, "source" => src, "target" => target }
      end } }
end

aggregates = stored["Root"].map do |root|
  name   = val[root[:name]]
  shapes = stored["Shape"].select { |s| val[s[:root_id]] == name }
  verbs  = stored["Verb"].select  { |x| val[x[:root_id]] == name }
  asks   = stored["Ask"].select   { |q| val[q[:root_id]] == name }

  life = if blank[val[root[:state_field]]]
           { "field" => val[root[:state_field]], "default" => val[root[:state_start]],
             "transitions" => Array(root[:transitions]).map { |t|
               { "command" => t[:command], "from_state" => t[:from_state], "to_state" => t[:to_state] } } }
         end

  { "name" => name, "description" => val[root[:description]],
    "identified_by" => blank[val[root[:identity]]], "lifecycle" => life,
    "entities" => stored["Piece"].select { |p| val[p[:owner]] == name }.map { |p|
      owner = "#{name}.#{val[p[:name]]}"
      plife = if blank[val[p[:state_field]]]
                { "field" => val[p[:state_field]], "default" => val[p[:state_start]],
                  "transitions" => Array(p[:transitions]).map { |t2|
                    { "command" => t2[:command], "from_state" => t2[:from_state], "to_state" => t2[:to_state] } } }
              end
      { "attributes" => Array(p[:attributes]).map { |a|
          { "default" => (a[:default].to_s.empty? ? nil : JSON.parse(a[:default].to_s)), "list" => truthy[a[:list]], "name" => a[:name], "type" => a[:type] } },
        "commands" => stored["Verb"].select { |x| val[x[:root_id]] == owner }.map { |x| build_verb.call(x) },
        "description" => val[p[:description]], "identified_by" => blank[val[p[:identity]]],
        "lifecycle" => plife, "name" => val[p[:name]],
        "queries" => stored["Ask"].select { |q| val[q[:root_id]] == owner }.map { |q| build_ask.call(q) } } },
    "attributes" => Array(root[:attributes]).map { |a|
      { "default" => nil, "list" => truthy[a[:list]], "name" => a[:name], "type" => a[:type] } },
    "value_objects" => shapes.map { |s|
      { "attributes" => Array(s[:fields]).map { |f|
          { "default" => (f[:default].to_s.empty? ? nil : JSON.parse(f[:default].to_s)), "list" => truthy[f[:list]], "name" => f[:name], "type" => f[:type] } },
        "invariants" => Array(s[:assertions]).map { |i|
          { "canonical" => i[:canonical], "description" => i[:description] } },
        "members" => stored["Member"].select { |m| val[m[:shape]] == s[:__id] }
                        .map { |m| Array(m[:pairs]).map { |pr| [pr[:key], pr[:value]] } },
        "name" => val[s[:name]] } },
    "queries" => asks.map { |q|
      { "attributes" => Array(q[:arguments]).map { |a|
          { "default" => (a[:default].to_s.empty? ? nil : JSON.parse(a[:default].to_s)), "list" => truthy[a[:list]], "name" => a[:name], "type" => a[:type] } },
        "description" => blank[val[q[:purpose]]],
        "limit" => (blank[val[q[:ceiling]]] ? { "value" => val[q[:ceiling]] } : nil),
        "name" => val[q[:name]],
        "order_by" => (blank[val[q[:order_field]]] ? { "direction" => val[q[:order_way]], "field" => val[q[:order_field]] } : nil),
        "wheres" => Array(q[:filters]).map { |w| { "field" => w[:field], "op" => w[:op], "value" => w[:value] } } } },
    "commands" => verbs.map { |x| build_verb.call(x) } }
end

ch = stored["Chapter"].first || {}
rebuilt = {
  "name" => val[ch[:name]], "vision" => val[ch[:vision]], "classification" => val[ch[:classification]],
  "version" => chapter["version"],
  "canonical_form" => Array(ch[:normalisations]).map { |n|
    { "boundary" => n[:boundary], "position" => n[:position], "replacement" => n[:replacement],
      "source_token" => n[:source_token], "strategy" => n[:strategy] } },
  "policies" => stored["Reaction"].map { |p|
    { "name" => val[p[:name]], "on_event" => val[p[:watches]],
      "target_domain" => blank[val[p[:reaches]]], "trigger_command" => val[p[:fires]] } },
  "process_managers" => stored["Saga"].map { |s|
    legs = stored["Leg"].select { |l| val[l[:saga]] == val[s[:name]] }
    { "correlates_by" => val[s[:correlate]], "ends_on" => val[s[:ends]], "name" => val[s[:name]],
      "starts_on" => val[s[:starts]], "states" => Array(s[:states]).map { |x| x[:name] },
      "handlers" => legs.map { |l|
        sends = stored["Send"].select { |d| val[d[:leg]] == l[:__id] }
        { "dispatches" => sends.map { |d|
            { "command_name" => val[d[:verb]],
              "with" => Array(d[:bindings]).map { |b| [b[:key], b[:value]] } } },
          "event_type" => val[l[:answers]],
          "from_state" => val[l[:from_state]], "to_state" => val[l[:to_state]] } } } },
  "read_models" => stored["Projection"].map { |m|
    { "aggregate_heads" => Array(m[:heads]).map { |h|
        { "aggregate" => h[:aggregate], "as" => h[:as], "many" => truthy[h[:many]] } },
      "description" => val[m[:purpose]], "name" => val[m[:name]],
      "query_name" => val[m[:query_name]], "reference_name" => val[m[:ref_name]],
      "reference_target" => val[m[:ref_target]] } },
  "aggregates" => aggregates
}

norm = ->(o) { JSON.parse(JSON.generate(o)) }
deep = nil
deep = ->(o) {
  case o
  when Hash  then o.sort_by { |k, _| k.to_s }.to_h { |k, x| [k, deep.call(x)] }
  when Array then o.map { |x| deep.call(x) }
  else o
  end
}
a = JSON.pretty_generate(deep.call(norm.call(rebuilt)))
b = JSON.pretty_generate(deep.call(norm.call(chapter)))
File.write("/tmp/meta.rebuilt.json", a)
File.write("/tmp/meta.expected.json", b)

puts JSON.pretty_generate(
  aggregates: chapter.fetch("aggregates").length,
  commands: chapter.fetch("aggregates").sum { |x| x.fetch("commands", []).length },
  queries: chapter.fetch("aggregates").sum { |x| x.fetch("queries", []).length },
  policies: chapter.fetch("policies", []).length,
  process_managers: chapter.fetch("process_managers", []).length,
  read_models: chapter.fetch("read_models", []).length,
  refusals: refusals.length, first_refusals: refusals.first(5),
  full_ir: (a == b ? "MATCHES" : "DIFFERS — /tmp/meta.{rebuilt,expected}.json")
)
