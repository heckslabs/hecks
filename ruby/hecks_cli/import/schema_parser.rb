module Hecks
  module Import
    # Hecks::Import::SchemaParser
    #
    # Evaluates a Rails schema.rb in a sandbox that captures create_table
    # calls. Returns an array of table hashes with columns and foreign keys.
    # schema.rb is a Ruby DSL designed to be eval'd — no parsing needed.
    #
    #   SchemaParser.new("db/schema.rb").parse
    #   # => [{ name: "pizzas", columns: [{name: "name", type: :string}], foreign_keys: ["restaurant_id"] }]
    #
    class SchemaParser
      SKIP_TABLES = %w[
        schema_migrations ar_internal_metadata
        active_storage_blobs active_storage_attachments active_storage_variant_records
        action_text_rich_texts action_mailbox_inbound_emails
      ].freeze

      SKIP_COLUMNS = %w[id created_at updated_at].freeze

      def initialize(schema_path)
        @schema_path = schema_path
      end

      def parse
        content = File.read(@schema_path)
        sandbox = SchemaSandbox.new
        # schema.rb calls ActiveRecord::Schema.define { ... }
        # We stub that constant so the block routes to our sandbox.
        with_fake_ar(sandbox) { eval(content, TOPLEVEL_BINDING.dup, @schema_path) } # rubocop:disable Security/Eval
        sandbox.tables.reject { |t| SKIP_TABLES.include?(t[:name]) }
      end

      private

      def with_fake_ar(sandbox)
        had_ar = Object.const_defined?(:ActiveRecord)
        old_ar = Object.const_get(:ActiveRecord) if had_ar
        fake_schema = Class.new do
          define_method(:define) { |**_opts, &block| sandbox.instance_eval(&block) if block }
        end
        fake_ar = Module.new { const_set(:Schema, fake_schema.new) }
        Object.send(:remove_const, :ActiveRecord) if had_ar
        Object.const_set(:ActiveRecord, fake_ar)
        yield
      ensure
        Object.send(:remove_const, :ActiveRecord) if Object.const_defined?(:ActiveRecord)
        Object.const_set(:ActiveRecord, old_ar) if had_ar
      end

      # Minimal sandbox that captures create_table calls.
      class SchemaSandbox
        attr_reader :tables

        def initialize
          @tables = []
        end

        def create_table(name, **_opts)
          collector = ColumnCollector.new
          yield collector if block_given?
          @tables << {
            name:         name.to_s,
            columns:      collector.columns.reject { |c| SKIP_COLUMNS.include?(c[:name]) },
            foreign_keys: collector.foreign_keys
          }
        end

        def enable_extension(*); end
        def add_index(*); end
        def add_foreign_key(*); end
      end

      # Captures t.string, t.integer, t.references, etc.
      class ColumnCollector
        attr_reader :columns, :foreign_keys

        def initialize
          @columns      = []
          @foreign_keys = []
        end

        def timestamps(**); end
        def index(*); end

        def method_missing(type, name = nil, **opts, &block)
          return if name.nil?
          name = name.to_s
          if type == :references || type == :belongs_to
            @foreign_keys << "#{name}_id"
            # Use to_table if provided (e.g. foreign_key: { to_table: :gunslingers })
            fk = opts[:foreign_key]
            target = if fk.is_a?(Hash) && fk[:to_table]
                       fk[:to_table].to_s.sub(/s$/, "")
                     else
                       name
                     end
            @columns << { name: "#{name}_id", type: :reference, target: target }
          else
            col = { name: name, type: type }
            col[:enum] = opts[:enum] if opts[:enum]
            col[:default] = opts[:default] if opts.key?(:default)
            @columns << col
          end
        end

        def respond_to_missing?(*, **)
          true
        end
      end
    end
  end
end
