Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Workshop::HandlesParagraph,
  base_dir: File.expand_path("aggregate_handle", __dir__)
)

module Hecks
  class Workshop
    # Hecks::Workshop::AggregateHandle
    #
    # Interactive handle for incrementally building a single aggregate in the
    # REPL. Wraps an AggregateBuilder and provides add/remove methods that
    # print feedback as you go. Supports one-line dot syntax via method_missing.
    #
    #   Post.title String         # implicit attribute
    #   Post.create               # implicit command, returns CommandHandle
    #   Post.create.title String  # add attribute to command
    #   Post.lifecycle :status, default: "draft"
    #   Post.transition "PublishPost" => "published"
    #
    class AggregateHandle
      include HecksTemplating::NamingHelpers
      include Presenter
      include BehaviorMethods
      include ConstraintMethods
      include QueryMethods
      include ImplicitSyntax

    attr_reader :name

    def initialize(name, builder, domain_module:, workshop: nil)
      @name = name
      @builder = builder
      @domain_module = domain_module
      @workshop = workshop
      @command_handles = {}
    end

    def attr(name, type = String, **options)
      check_duplicate_attr!(name)
      @builder.attribute(name, type, **options)
      puts "#{name} attribute added to #{@name}"
      self
    end

    def reference_to(type, role: nil)
      @builder.reference_to(type, role: role)
      role_name = role || type.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                                   .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      puts "reference_to #{type} (as #{role_name}) added to #{@name}"
      check_bidirectional(type)
      self
    end

    { remove: :attributes, remove_command: :commands, remove_event: :events,
      remove_policy: :policies, remove_validation: :validations,
      remove_query: :queries, remove_scope: :scopes,
      remove_specification: :specifications, remove_subscriber: :subscribers,
      remove_value_object: :value_objects, remove_entity: :entities }.each do |method, collection|
      define_method(method) do |name|
        list = @builder.send(collection)
        key = collection == :attributes ? name.to_sym : name.to_s
        removed = list.reject! { |item| (item.respond_to?(:name) ? item.name : item.field) == key }
        label = collection.to_s.chomp("s").tr("_", " ")
        puts removed ? "#{name} #{label} removed from #{@name}" : "no #{label} #{name} on #{@name}"
        self
      end
    end

    def value_object(name, &block)
      name = normalize_name(name)
      @builder.value_object(name, &block)
      puts "#{name} value object created on #{@name}"
      self
    end

    def entity(name, &block)
      name = normalize_name(name)
      @builder.entity(name, &block)
      puts "#{name} entity created on #{@name}"
      self
    end

    def verb(word)
      @workshop&.add_verb(word)
      puts "#{word} verb registered"
      self
    end

    def attributes
      @builder.attributes.map(&:name)
    end

    def commands
      @builder.commands.map(&:name)
    end

    def value_objects
      @builder.value_objects.map { |vo| vo.respond_to?(:name) ? vo.name : vo.build.name }
    end

    def entities
      @builder.entities.map { |ent| ent.respond_to?(:name) ? ent.name : ent.build.name }
    end

    def list_of(type) = { list: type }

    private

    def check_duplicate_attr!(name)
      if @builder.attributes.any? { |a| a.name == name.to_sym }
        raise ArgumentError, "#{@name} already has attribute :#{name}"
      end
    end

    def normalize_name(name)
      domain_constant_name(name)
    end

    def infer_command_name(snake)
      parts = snake.to_s.split("_")
      if parts.size == 1
        parts.first.capitalize + @name
      else
        parts.map(&:capitalize).join
      end
    end

    def check_bidirectional(target_name)
      return unless @workshop
      domain = @workshop.to_domain
      target_agg = domain.aggregates.find { |a| a.name == target_name.to_s }
      return unless target_agg
      back_refs = (target_agg.references || []).map { |r| r.type.to_s }
      if back_refs.include?(@name)
        puts "  !! WARNING: Bidirectional reference detected between #{@name} and #{target_name}."
        puts "     #{target_name} already references #{@name}. Aggregates should not reference"
        puts "     each other — one side should use events/policies instead."
      end
    end
  end
  end
end
