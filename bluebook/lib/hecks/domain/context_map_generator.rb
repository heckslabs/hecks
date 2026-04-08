# Hecks::ContextMapGenerator
#
# Generates a Mermaid diagram showing bounded context relationships across
# multiple domains. Identifies cross-domain event flows via reactive policies,
# shared references via attribute naming conventions, and renders each domain
# as a subgraph with upstream/downstream arrows.
#
#   domains = [pizzas_domain, billing_domain, shipping_domain]
#   Hecks::ContextMapGenerator.new(domains).generate
#   # => "graph TD\n    subgraph Pizzas\n    ..."
#
#   Hecks::ContextMapGenerator.new(domains).generate_text
#   # => "Bounded Contexts:\n  [Pizzas] ..."
#
class Hecks::ContextMapGenerator
  include HecksTemplating::NamingHelpers

  # @param domains [Array<Hecks::BluebookModel::Structure::Domain>] loaded domain IRs
  def initialize(domains)
    @domains = domains
  end

  # Generate a Mermaid graph TD diagram with subgraphs for each domain
  # and arrows for cross-domain relationships.
  #
  # @return [String] Mermaid diagram source code
  def generate
    lines = ["graph TD"]
    subgraphs(lines)
    relationship_arrows(lines)
    shared_kernel_annotations(lines)
    lines.join("\n")
  end

  # Generate a plain-text context map summary.
  #
  # @return [String] human-readable context map
  def generate_text
    lines = []
    lines << "Bounded Contexts:"
    @domains.each do |domain|
      aggs = domain.aggregates.map(&:name).join(", ")
      lines << "  [#{domain.name}] Aggregates: #{aggs}"
    end
    lines << ""
    lines << "Relationships:"
    relationships.each do |rel|
      lines << "  #{rel[:upstream]} --> #{rel[:downstream]}"
      lines << "    Event: #{rel[:event]} | Policy: #{rel[:policy]}"
    end
    lines << ""
    kernels = shared_kernels
    if kernels.any?
      lines << "Shared Kernels:"
      kernels.each { |kernel_name| lines << "  [#{kernel_name}]" }
    end
    lines.join("\n")
  end

  # Derive cross-domain relationships from reactive policies.
  # A relationship exists when a policy in one domain listens for an event
  # that originates in a different domain.
  #
  # @return [Array<Hash>] unique relationships with :upstream, :downstream, :event, :policy keys
  def relationships
    @relationships ||= derive_relationships
  end

  # Identify domains that are referenced by two or more other domains
  # via attribute naming conventions (e.g. pizza_id references Pizzas).
  #
  # @return [Array<String>] domain names acting as shared kernels
  def shared_kernels
    @shared_kernels ||= find_shared_kernels
  end

  private

  def subgraphs(lines)
    @domains.each do |domain|
      node_id = safe_id(domain.name)
      lines << "    subgraph #{node_id}[#{domain.name}]"
      domain.aggregates.each do |agg|
        agg_id = "#{node_id}_#{safe_id(agg.name)}"
        lines << "        #{agg_id}[#{agg.name}]"
      end
      lines << "    end"
    end
  end

  def relationship_arrows(lines)
    relationships.each do |rel|
      from_id = safe_id(rel[:upstream])
      to_id = safe_id(rel[:downstream])
      label = rel[:event]
      lines << "    #{from_id} -->|#{label}| #{to_id}"
    end
  end

  def shared_kernel_annotations(lines)
    shared_kernels.each do |kernel_name|
      lines << "    style #{safe_id(kernel_name)} fill:#ffd,stroke:#aa0"
    end
  end

  def derive_relationships
    rels = []
    @domains.each do |consumer|
      all_reactive_policies(consumer).each do |policy|
        source = find_event_source(policy.event_name)
        next if source == consumer.name
        next unless source

        rels << {
          upstream: source,
          downstream: consumer.name,
          event: policy.event_name,
          policy: policy.name,
          conditional: !!policy.condition
        }
      end
    end
    rels.uniq { |rel| [rel[:upstream], rel[:downstream], rel[:event]] }
  end

  def all_reactive_policies(domain)
    agg_policies = domain.aggregates.flat_map { |agg| agg.policies.select(&:reactive?) }
    domain_policies = domain.policies.select(&:reactive?)
    agg_policies + domain_policies
  end

  def find_event_source(event_name)
    @domains.each do |domain|
      domain.aggregates.each do |agg|
        return domain.name if agg.events.any? { |event| event.name == event_name }
      end
    end
    nil
  end

  def find_shared_kernels
    agg_to_domain = {}
    @domains.each do |domain|
      domain.aggregates.each { |agg| agg_to_domain[agg.name] = domain.name }
    end

    ref_counts = Hash.new { |hash, key| hash[key] = Set.new }
    @domains.each do |domain|
      domain.aggregates.each do |agg|
        agg.attributes.each do |attr|
          next unless attr.name.to_s.end_with?("_id")
          check_attribute_references(attr, agg_to_domain, domain.name, ref_counts)
        end
      end
    end
    ref_counts.select { |_, referrers| referrers.size >= 2 }.keys
  end

  def check_attribute_references(attr, agg_to_domain, current_domain, ref_counts)
    agg_to_domain.each do |agg_name, owner_domain|
      next if owner_domain == current_domain
      snake = bluebook_snake_name(agg_name)
      parts = snake.split("_")
      matched = parts.each_index.any? { |idx| attr.name.to_s == parts.drop(idx).join("_") + "_id" }
      ref_counts[owner_domain].add(current_domain) if matched
    end
  end

  def safe_id(name)
    name.gsub(/[^A-Za-z0-9_]/, "_")
  end
end
