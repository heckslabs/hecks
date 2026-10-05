# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      class Table
        # One row with its defaults filled in.
        Row = Struct.new(:path, :kind, :render, :auth, :verbs, :cache, :origin, :source,
                         :indexable, :switch, :off, :preview, :label, :seo, :redirect_to, :aliases,
                         :nav_group, :nav_order, :mobile_order, :footer_column, :footer_order,
                         :admin_key, :admin_order, :compress, :alb_rule, :cdn,
                         :seo_title, :edge_verbs, :mobile_heading, :explicit_cache, keyword_init: true)

        # Turns a declared member into a `Row`: checks its fields and their types, fills the
        # defaults, and checks each closed-set value against the Site chapter's vocabulary.
        class RowBuilder
          # The fields a row may carry, with the Ruby class each takes (`:bool` is true or false).
          FIELDS = { path: String, kind: String, render: String, auth: String, methods: String,
                     cache: String, origin: String, source: String, indexable: :bool, switch: String,
                     off: :bool, preview: String, label: String, seo: String, redirect_to: String,
                     aliases: String, nav_group: String, nav_order: Integer, mobile_order: Integer,
                     footer_column: String, footer_order: Integer, admin_key: String,
                     admin_order: Integer, compress: :bool, alb_rule: String, cdn: :bool,
                     seo_title: String, edge_methods: String, mobile_heading: String }.freeze

          # The value objects of the Site chapter's `Route` aggregate whose members are the closed
          # sets, by the row field each constrains.
          VOCABULARY = { kind: "Kind", render: "Render", auth: "Auth", cache: "CacheClass",
                         origin: "Origin", preview: "Preview" }.freeze

          # A source that names a command or query, whose forms-scheme URL is the route's path.
          DERIVED_SOURCE = /\A(command|query):([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\z/
          NAMED_SOURCE = /\A(global|collection):[a-z0-9_-]+\z/

          # @param vocabulary [Hash{Symbol => Array<String>}] the closed sets
          # @param registry [Runtime::Registry, nil] where a `command:` or `query:` is looked up
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(vocabulary:, registry:, problems:)
            @vocabulary = vocabulary
            @registry = registry
            @problems = problems
          end

          # @param member [Hash{Symbol => Object}] the declared fields of one row
          # @param index [Integer] the row's position, for a message about a row with no path
          # @return [Row] the row with its defaults filled in; its problems are in `problems`
          def call(member, index)
            label = member[:path] || "row #{index + 1}"
            fields = checked_fields(member, label)
            source = fields[:source] || "none"
            path = fields[:path] || derived_path(source)
            label = path || label
            check_source(label, source)
            verbs = fields.delete(:methods)
            edge_verbs = fields.delete(:edge_methods)
            row = Row.new(**fields, verbs: verbs, edge_verbs: edge_verbs, path: path, source: source,
                                    explicit_cache: !fields[:cache].nil?,
                                    kind: fields[:kind] || default_kind(source), auth: fields[:auth] || "public",
                                    origin: fields[:origin] || default_origin(source))
            fill_defaults(row)
            check_values(row, label)
            problem(label, "needs a path") if row.path.nil?
            row
          end

          private

          def checked_fields(member, label)
            member.each_key do |key|
              problem(label, "has no field #{key}; fields are #{FIELDS.keys.join(', ')}") unless FIELDS.key?(key)
            end
            known = member.slice(*FIELDS.keys)
            known.each { |key, value| check_type(label, key, value) }
            known
          end

          def check_type(label, key, value)
            expected = FIELDS.fetch(key)
            return if expected == :bool ? [true, false].include?(value) : value.is_a?(expected)

            problem(label, "has #{key} #{value.inspect}; #{key} is #{expected == :bool ? 'true or false' : "a #{expected}"}")
          end

          def default_kind(source) = source.match?(DERIVED_SOURCE) ? "endpoint" : "page"

          def default_origin(source) = source.match?(DERIVED_SOURCE) ? "domain" : "website"

          # A `command:` or `query:` source leaves the path to the forms scheme,
          # `/Chapter/Aggregate/Verb`.
          def derived_path(source)
            match = DERIVED_SOURCE.match(source) or return nil
            "/#{match[2]}/#{match[3]}/#{match[4]}"
          end

          def fill_defaults(row)
            row.off = false if row.off.nil?
            row.compress = true if row.compress.nil?
            row.cdn = true if row.cdn.nil?
            row.render ||= row.kind == "page" ? "prerender" : "ssr"
            row.verbs = list(row.verbs || (row.source.start_with?("command:") ? "POST" : "GET"))
            row.edge_verbs = row.edge_verbs.nil? ? row.verbs : list(row.edge_verbs)
            row.aliases = list(row.aliases)
            row.cache ||= default_cache(row)
            row.indexable = indexable_by_default?(row) if row.indexable.nil?
            fill_slots(row)
          end

          def fill_slots(row)
            row.preview ||= "public"
            row.switch ||= ""
            row.footer_order ||= 0 if row.footer_column
            row.admin_order ||= 0 if row.admin_key
          end

          def list(text) = text.to_s.split(",").map(&:strip).reject(&:empty?)

          def default_cache(row)
            return "no_store" if row.auth != "public" || row.kind == "endpoint"

            row.origin == "assets" ? "immutable" : "page"
          end

          def indexable_by_default?(row) = row.kind == "page" && row.auth == "public" && !row.off

          def check_values(row, label)
            VOCABULARY.each_key do |field|
              next if @vocabulary.fetch(field).include?(row[field])

              problem(label, "has #{field} #{row[field].inspect}; #{field} is one of #{@vocabulary.fetch(field).join(', ')}")
            end
            check_verbs(row, label)
          end

          def check_verbs(row, label)
            { "method" => row.verbs, "edge method" => row.edge_verbs }.each do |what, verbs|
              verbs.each do |verb|
                next if @vocabulary.fetch(:http_method).include?(verb)

                problem(label, "has #{what} #{verb.inspect}; methods are #{@vocabulary.fetch(:http_method).join(', ')}")
              end
            end
            return if (row.verbs - row.edge_verbs).empty?

            problem(label, "has edge_methods #{row.edge_verbs.join(',')}, which leave out its methods " \
                           "#{(row.verbs - row.edge_verbs).join(',')}; the edge must allow every verb the route answers")
          end

          def check_source(label, source)
            match = DERIVED_SOURCE.match(source)
            unless match || source == "none" || source.match?(NAMED_SOURCE)
              problem(label, "has source #{source.inspect}; use none, global:<slug>, collection:<name>, " \
                             "command:<Chapter>.<Aggregate>.<Command> or query:<Chapter>.<Aggregate>.<Query>")
            end
            return unless match && @registry
            return if verb_exists?(*match.captures)

            problem(label, "names #{source}, which no attached chapter declares")
          end

          def verb_exists?(word, chapter, aggregate, name)
            found = @registry.bluebook(chapter)&.aggregate(aggregate) or return false
            (word == "command" ? found.commands : found.queries).any? { |verb| verb.hecks_name == name }
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
