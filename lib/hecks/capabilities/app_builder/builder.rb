# Hecks::Capabilities::AppBuilder::Builder
#
# Takes planned additions and writes .bluebook code. Uses Claude
# to generate the DSL, or falls back to template generation.
#
#   builder = Builder.new(runtime)
#   builder.build(additions)
#   # => { file: "hecks/user_auth.bluebook", content: "..." }
#
module Hecks
  module Capabilities
    module AppBuilder
      class Builder
        def initialize(runtime)
          @runtime = runtime
        end

        def build(additions)
          return { error: "No additions to build" } unless additions&.any?

          code = generate_bluebook(additions)
          filename = infer_filename(additions)
          write_path = File.join(find_hecks_dir, filename)

          File.write(write_path, code)
          { file: write_path, content: code, additions_count: additions.size }
        rescue => e
          { error: "Build failed: #{e.message}" }
        end

        private

        def generate_bluebook(additions)
          aggregates = {}
          additions.each do |a|
            a = a.transform_keys(&:to_s)
            case a["kind"]
            when "aggregate"
              aggregates[a["name"]] = { desc: a["description"], attrs: [], cmds: [] }
            when "attribute"
              agg = aggregates[a["parent"]] ||= { desc: "", attrs: [], cmds: [] }
              agg[:attrs] << a["name"]
            when "command"
              agg = aggregates[a["parent"]] ||= { desc: "", attrs: [], cmds: [] }
              agg[:cmds] << a["name"]
            end
          end

          domain_name = aggregates.keys.first || "NewDomain"
          lines = ["Hecks.bluebook \"#{domain_name}\" do"]

          aggregates.each do |name, data|
            lines << "  aggregate \"#{name}\" do"
            lines << "    description \"#{data[:desc]}\"" if data[:desc] && !data[:desc].empty?
            data[:attrs].each { |attr| lines << "    attribute :#{attr}, String" }
            data[:cmds].each do |cmd|
              lines << "    command \"#{cmd}\" do"
              lines << "      emits \"#{cmd.sub(/^[A-Z]/, &:downcase)}ed\""
              lines << "    end"
            end
            lines << "  end"
          end

          lines << "end"
          lines.join("\n") + "\n"
        end

        def infer_filename(additions)
          agg = additions.find { |a| (a["kind"] || a[:kind]) == "aggregate" }
          name = agg ? (agg["name"] || agg[:name]) : "new_feature"
          name.gsub(/([A-Z])/, '_\1').sub(/^_/, "").downcase + ".bluebook"
        end

        def find_hecks_dir
          root = @runtime.respond_to?(:root) ? @runtime.root : Dir.pwd
          dir = File.join(root, "hecks")
          Dir.mkdir(dir) unless File.directory?(dir)
          dir
        end
      end
    end
  end
end
