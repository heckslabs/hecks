# = Hecks::Chapters::Extensions::WebExplorerChapter
#
# Self-describing sub-chapter for web explorer internals:
# IR introspection, event introspection, pagination, rendering,
# runtime bridge, and template binding.
#
#   Hecks::Chapters::Extensions::WebExplorerChapter.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::WebExplorerChapter
      #
      # Bluebook sub-chapter for web explorer internals: IR introspection, pagination, rendering, and runtime bridge.
      #
      module WebExplorerChapter
        def self.define(b)
          b.aggregate "IRIntrospector", "Structural queries from Bluebook IR for web explorer display" do
            command("Introspect") { attribute :domain_name, String }
            command("FindCommand") { attribute :aggregate_name, String; attribute :command_name, String }
          end

          b.aggregate "EventIntrospector", "Reads and filters events from EventBus instances for web display" do
            command("ListEvents") { attribute :type_filter, String; attribute :aggregate_filter, String }
          end

          b.aggregate "Paginator", "Offset-based pagination for web explorer list views" do
            command("Paginate") { attribute :page, Integer; attribute :per_page, Integer }
          end

          b.aggregate "Renderer", "ERB template rendering with layout wrapping and HTML escaping" do
            command("Render") { attribute :template_name, String }
          end

          b.aggregate "RuntimeBridge", "Isolates runtime CRUD access behind a clean interface for web explorer" do
            command("FindAll") { attribute :aggregate_name, String }
            command("ExecuteCommand") { attribute :aggregate_name, String; attribute :method_name, String }
          end

          b.aggregate "WebExplorerTemplateBinding", "Clean binding for ERB templates where locals become methods" do
            command("Bind") { attribute :template_name, String }
          end
        end
      end
    end
  end
end
