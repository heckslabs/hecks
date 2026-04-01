# Hecks::WebExplorer::RuntimeBridge
#
# Isolates all runtime CRUD access behind a clean interface. The Web
# Explorer uses this bridge for data operations (find, all, create)
# while getting all structural information from the IRIntrospector.
# This eliminates Object.const_get, respond_to?, and dynamic dispatch
# from the UI layer.
#
#   bridge = RuntimeBridge.new(mod)
#   bridge.find_all("Pizza")            # => [obj, ...]
#   bridge.find_by_id("Pizza", id)      # => obj or nil
#   bridge.execute_command("Pizza", :create, name: "Margherita")
#
module Hecks
  module WebExplorer
    class RuntimeBridge
      include HecksTemplating::NamingHelpers

      def initialize(mod)
        @mod = mod
      end

      def find_all(agg_name)
        klass_for(agg_name).all
      end

      def find_by_id(agg_name, id)
        klass_for(agg_name).find(id)
      end

      def execute_command(agg_name, method_name, attrs)
        result = klass_for(agg_name).send(method_name, **attrs)
        extract_id(result)
      end

      def read_attribute(obj, attr_name)
        obj.send(attr_name).to_s
      end

      def read_id(obj)
        obj.id
      end

      def evaluate_computed(obj, block)
        obj.instance_eval(&block).to_s
      end

      def resolve_reference_display(obj, attr, ref_agg_name)
        raw = obj.send(attr.name).to_s
        return truncate_id(raw) unless ref_agg_name
        ref_klass = klass_for(ref_agg_name)
        found = ref_klass.all.find { |x| x.id == raw }
        found&.respond_to?(:name) ? found.name.to_s : truncate_id(raw)
      rescue NameError
        truncate_id(raw)
      end

      private

      def klass_for(agg_name)
        safe = domain_constant_name(agg_name)
        @mod.const_get(safe)
      end

      def extract_id(result)
        if result.respond_to?(:aggregate)
          result.aggregate.id
        else
          result.id
        end
      end

      def truncate_id(raw)
        raw[0..7] + "..."
      end
    end
  end
end
