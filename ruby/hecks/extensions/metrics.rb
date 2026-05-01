# Hecks::Metrics
#
# Observability extension for tracking changes to metric-tagged aggregate
# attributes. Reads +aggregate_capabilities+ tags where +tag == :metric+ from
# the Hecksagon IR, then installs command bus middleware that captures
# before/after values for each tagged attribute on every command execution.
#
# Emitted entries are appended to +Hecks.metric_log+ by default. When a
# custom sink is registered via +Hecks.metric_sink=+, each entry is also
# forwarded to +sink.call(entry)+.
#
# Future gem: hecks_metrics
#
# DSL (in *Hecksagon file):
#   aggregate "Pizza" do
#     capability.order_count.metric
#     capability.revenue.metric
#   end
#
# Reading the log:
#   Hecks.metric_log.last
#   # => { aggregate: "Pizza", attribute: :order_count,
#   #      old: 0, new: 1, command: "AddOrder", timestamp: ... }
#
# Custom sink (StatsD, Prometheus, etc.):
#   Hecks.metric_sink = ->(entry) { StatsD.gauge(entry[:attribute], entry[:new]) }
#
module Hecks; end
# Hecks::Metrics
#
# Observability extension that tracks changes to metric-tagged aggregate attributes on every command execution.
#
module Hecks::Metrics
  # Extract the names of metric-tagged attributes from the Hecksagon IR
  # for a given aggregate name.
  #
  # @param hecksagon [Hecksagon::Structure::Hecksagon, nil]
  # @param agg_name [String]
  # @return [Array<Symbol>] attribute names tagged with :metric
  def self.metric_fields(hecksagon, agg_name)
    return [] unless hecksagon
    tags = hecksagon.aggregate_capabilities[agg_name.to_s] || []
    tags.select { |t| t[:tag] == :metric }.map { |t| t[:attribute].to_sym }
  end

  # Read metric field values from an entity object.
  #
  # @param entity [Object, nil] the aggregate instance
  # @param fields [Array<Symbol>] attribute names
  # @return [Hash{Symbol => Object}] attribute name → current value
  def self.read_values(entity, fields)
    return {} unless entity
    fields.each_with_object({}) do |name, h|
      h[name] = entity.respond_to?(name) ? entity.send(name) : nil
    end
  end

  # Attempt to find the existing entity for an update/transition command.
  # Returns nil for create commands (no self-referencing ID attribute).
  #
  # Walks the command's instance variables looking for one whose name ends
  # with "_id" and matches an ID stored in the repository, or falls back to
  # probing common id attributes.
  #
  # @param command [Object] the command instance
  # @param repo [Object] the repository (responds to +find+)
  # @return [Object, nil] the existing entity or nil
  def self.find_before(command, repo)
    # Collect candidate ID values from the command
    ivars = command.instance_variables
    ivars.each do |ivar|
      val = command.instance_variable_get(ivar)
      next unless val.is_a?(String) || val.respond_to?(:id)
      entity_id = val.respond_to?(:id) ? val.id : val
      found = repo.find(entity_id) rescue nil
      return found if found
    end
    nil
  rescue
    nil
  end
end

Hecks.describe_extension(:metrics,
  description: "Metric change tracking for tagged aggregate attributes",
  adapter_type: :driven,
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:metrics) do |domain_mod, domain, runtime|
  # Build a lookup: aggregate_name => [metric_field_symbols]
  hecksagon = Hecks.last_hecksagon
  metric_lookup = {}
  domain.aggregates.each do |agg|
    fields = Hecks::Metrics.metric_fields(hecksagon, agg.name)
    metric_lookup[agg.name] = fields unless fields.empty?
  end

  # Initialize global metric log and sink on Hecks module (once).
  unless Hecks.respond_to?(:metric_log)
    Hecks.instance_variable_set(:@_metric_log, [])
    Hecks.instance_variable_set(:@_metric_sink, nil)
    Hecks.define_singleton_method(:metric_log) { @_metric_log }
    Hecks.define_singleton_method(:metric_sink=) { |s| @_metric_sink = s }
    Hecks.define_singleton_method(:metric_sink) { @_metric_sink }
  end

  # Build command-to-aggregate lookup so middleware knows which aggregate
  # to query for the before-state.
  cmd_to_agg = {}
  domain.aggregates.each do |agg|
    next unless metric_lookup.key?(agg.name)
    agg.commands.each do |cmd|
      cmd_to_agg[cmd.name] = agg.name
    end
  end

  # Install middleware only when there are metric-tagged attributes.
  next if metric_lookup.empty?

  runtime.use :metrics do |command, next_handler|
    cmd_class_name = command.class.name.to_s.split("::").last
    agg_name = cmd_to_agg[cmd_class_name]

    before_values = {}
    if agg_name
      fields = metric_lookup[agg_name]
      repo = runtime[agg_name]
      entity_before = Hecks::Metrics.find_before(command, repo) if repo
      before_values = Hecks::Metrics.read_values(entity_before, fields)
    end

    result = next_handler.call

    if agg_name
      fields = metric_lookup[agg_name]
      entity_after = result.respond_to?(:aggregate) ? result.aggregate : result
      after_values = Hecks::Metrics.read_values(entity_after, fields)

      fields.each do |attr|
        old_val = before_values[attr]
        new_val = after_values[attr]
        next if old_val == new_val

        entry = {
          aggregate: agg_name,
          attribute: attr,
          old: old_val,
          new: new_val,
          command: cmd_class_name,
          timestamp: Time.now
        }
        Hecks.metric_log << entry
        Hecks.metric_sink&.call(entry)
      end
    end

    result
  end
end
