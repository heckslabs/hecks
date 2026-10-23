require "base64"
require "digest"

module Hecks
  module Projector
    module Exporter
      # The wasm plugins a registry loaded, for the IR's `plugins` key: everything a host needs to
      # answer a plugin's queries without the bluebook of the chapter that declares them. The
      # module itself rides in the IR, so every deploy that ships the IR ships the plugin too.
      module Plugins
        # Every plugin adapter in a registry, by name.
        #
        # @param registry [Runtime::Registry] the loaded registry
        # @return [Array<Hash{String => Object}>] `"adapter"`, `"runs"`, `"sha256"` and `"module"`
        #   (the module's bytes, base64), and `"queries"`: each answered question with
        #   `"references"`, its `reference_to` arguments mapped to the qualified aggregate each names
        def plugins(registry)
          registry.adapters.values.select(&:plugin?).sort_by(&:name).map { |adapter| plugin_hash(registry, adapter) }
        end

        def plugin_hash(registry, adapter)
          bytes = File.binread(adapter.plugin_path)
          {
            "adapter" => adapter.name,
            "runs"    => adapter.runs,
            "queries" => adapter.answered_queries.map { |question| plugin_query(registry, question) },
            "sha256"  => Digest::SHA256.hexdigest(bytes),
            "module"  => Base64.strict_encode64(bytes)
          }
        end

        # One answered question and its reference arguments; a question no loaded chapter declares
        # carries none, and the host refuses it the way the runtime would.
        def plugin_query(registry, question)
          chapter_name, rest = question.split("::", 2)
          aggregate_name, query_name = rest.split(".", 2)
          aggregate = registry.bluebook(chapter_name)&.aggregate(aggregate_name)
          query = aggregate&.query(query_name)
          { "question" => question, "references" => references(chapter_name, aggregate, query) }
        end

        def references(chapter_name, aggregate, query)
          return {} unless query

          query.attributes.select(&:reference?).to_h do |attribute|
            target = attribute.type.resolve || aggregate
            [attribute.name.to_s, "#{chapter_name}::#{target.hecks_name}"]
          end
        end
      end
    end
  end
end
