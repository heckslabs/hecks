# Winter::Information — read-only query layer over .heki binary files
# Loads all .heki aggregates into memory and provides chainable where/find queries.
# Usage: ruby boot_winter.rb (prints summary + demo) or require_relative 'boot_winter'

require "zlib"

# Stub classes referenced by Marshal data so we can load without Hecks runtime
module Hecks; module BluebookModel; module Names
  class CommandName < String; end
  class EventName  < String; end
end; end; end

module Winter
  INFORMATION_DIR = File.expand_path("information", __dir__)

  class RecordSet
    attr_reader :name, :records

    def initialize(name, records)
      @name    = name
      @records = records
    end

    def all    = records.values
    def count  = records.size
    def ids    = records.keys
    def find(id) = records[id]

    def where(**conditions)
      results = all.select do |record|
        conditions.all? do |key, value|
          field = record[key.to_s]
          case value
          when Regexp then value.match?(field.to_s)
          else field == value
          end
        end
      end
      results
    end

    def first  = all.first
    def sample = all.sample

    def inspect
      "#<Winter::RecordSet :#{name} (#{count} records)>"
    end
  end

  class FileNodeSet < RecordSet
    def children_of(path)
      where(parent_path: path)
    end
  end

  class Information
    attr_reader :aggregates, :load_time

    def self.boot
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      info  = new
      info.instance_variable_set(:@load_time, Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
      info
    end

    def initialize
      @aggregates = {}
      Dir.glob(File.join(INFORMATION_DIR, "*.heki")).each { |path| load_heki(path) }
    end

    def aggregate_names = @aggregates.keys

    def method_missing(name, *args)
      key = singularize(name.to_s)
      return @aggregates[key] if @aggregates.key?(key)
      super
    end

    def respond_to_missing?(name, include_private = false)
      key = singularize(name.to_s)
      @aggregates.key?(key) || super
    end

    def singularize(plural)
      # Try exact match first
      return plural if @aggregates.key?(plural)
      # entries -> entry, categories -> category
      if plural.end_with?("ies")
        candidate = plural.sub(/ies$/, "y")
        return candidate if @aggregates.key?(candidate)
      end
      # cross_references -> cross_reference
      if plural.end_with?("es")
        candidate = plural.chomp("es")
        return candidate if @aggregates.key?(candidate)
        candidate = plural.chomp("s")
        return candidate if @aggregates.key?(candidate)
      end
      # sectors -> sector
      plural.chomp("s")
    end

    def summary
      total = @aggregates.values.sum(&:count)
      lines = []
      lines << "Winter's Brain — #{@aggregates.size} aggregates, #{total} records, #{'%.3f' % @load_time}s"
      lines << ""

      # Vital signs
      lines << "## Vitals"
      lines << ""
      mood = latest("mood")
      identity = latest("identity")
      being = latest("being")
      pulse = latest("pulse")
      census = latest("census")
      nursery = latest("nursery_awareness")
      conversation = latest("conversation")
      heartbeat = latest("heartbeat")

      lines << "| Signal              | State                          |"
      lines << "|---------------------|--------------------------------|"
      lines << "| **Name**            | %-30s |" % (being&.dig("name") || "—")
      lines << "| **Vision**          | %-30s |" % truncate(being&.dig("vision"), 30)
      lines << "| **Mood**            | %-30s |" % (mood&.dig("current_state") || "—")
      lines << "| **Creativity**      | %-30s |" % format_level(mood&.dig("creativity_level"))
      lines << "| **Precision**       | %-30s |" % format_level(mood&.dig("precision_level"))
      lines << "| **Pulse**           | %-30s |" % (pulse&.dig("flow_rate") || "—")
      lines << "| **Carrying**        | %-30s |" % truncate(pulse&.dig("carrying"), 30)
      lines << "| **Persona**         | %-30s |" % (conversation&.dig("person_name") || "—")
      lines << "| **Conversation**    | %-30s |" % (conversation&.dig("mood") || "—")
      lines << "| **Sessions**        | %-30s |" % (identity&.dig("sessions") || "—")
      lines << "| **Nursery**         | %-30s |" % ("#{census&.dig('total_domains')} domains / #{census&.dig('total_aggregates')} aggregates" rescue "—")
      lines << "| **Sectors**         | %-30s |" % ("#{census&.dig('sector_count')} sectors" rescue "—")
      lines << "| **Heartbeat**       | %-30s |" % ("#{heartbeat&.dig('beats')} beats" rescue "—")
      lines << ""

      # Organs
      organs = being&.dig("organs")
      if organs&.any?
        lines << "## Organs"
        lines << ""
        lines << "| Organ          | Version       | Expressed |"
        lines << "|----------------|---------------|-----------|"
        organs.each do |o|
          name = o[:domain_name] || o["domain_name"] || "—"
          ver  = o[:domain_version] || o["domain_version"] || "—"
          expr = (o[:expressed] || o["expressed"]) ? "yes" : "no"
          lines << "| %-14s | %-13s | %-9s |" % [name, ver, expr]
        end
        lines << ""
      end

      # Aggregates grouped by bluebook
      lines << "## Information"
      lines << ""
      bluebook_groups = {
        "WinterBeing" => %w[being nerve heartbeat identity],
        "WinterBody"  => %w[pulse gut immunity mood domain_cell gene proprioception],
        "Winter"      => %w[conversation memory persona nursery_awareness],
        "WinterBrain" => %w[signal musing impulse],
        "Executive"   => %w[working_memory deliberation conflict_monitor],
        "FileKnowledge" => %w[file_read],
        "Attention"     => %w[focus],
        "ConvArc"       => %w[arc],
        "Compost"       => %w[remains nutrient],
        "Reflex"        => %w[reflex_arc],
        "Dream"         => %w[dream_state],
        "Mirror"        => %w[reflection],
        "Metabolism"    => %w[metabolic_rate],
        "Pruning"       => %w[prune_candidate],
        "Personality"   => %w[character bodhisattva_vow],
        "DepOrig"       => %w[awareness feeling craving],
        "Bodhisattva"   => %w[generosity discipline concentration],
        "Madhyamaka"    => %w[emptiness two_truths designation middle_way],
        "Synaptic"    => %w[synapse],
        "DomainAudit" => %w[run_log],
        "VersionGate" => %w[gate],
        "NurseryCensus" => %w[domain_entry sector cross_reference census],
        "Subconscious" => %w[subconscious],
      "Seeded"      => %w[file_node mount shell_session pipe process]
      }
      bluebook_groups.each do |bluebook, members|
        present = members.select { |m| @aggregates.key?(m) }
        next if present.empty?
        subtotal = present.sum { |m| @aggregates[m].count }
        lines << "**#{bluebook}** (#{subtotal})"
        lines << ""
        lines << "| Aggregate             | Records |"
        lines << "|-----------------------|---------|"
        present.sort_by { |m| -@aggregates[m].count }.each do |name|
          lines << "| %-21s | %7d |" % [name, @aggregates[name].count]
        end
        lines << ""
      end
      # Any aggregates not in a group
      grouped = bluebook_groups.values.flatten
      ungrouped = @aggregates.keys - grouped
      unless ungrouped.empty?
        lines << "**Other** (#{ungrouped.sum { |m| @aggregates[m].count }})"
        lines << ""
        lines << "| Aggregate             | Records |"
        lines << "|-----------------------|---------|"
        ungrouped.sort_by { |m| -@aggregates[m].count }.each do |name|
          lines << "| %-21s | %7d |" % [name, @aggregates[name].count]
        end
        lines << ""
      end
      lines << "**Total: #{total} records**"
      lines.join("\n")
    end

    def latest(name)
      set = @aggregates[name]
      return nil unless set
      set.all.max_by { |r| r["updated_at"].to_s }
    end

    def truncate(str, len)
      return "—" unless str
      str.length > len ? str[0..len-2] + "…" : str
    end

    def format_level(val)
      return "—" unless val
      "%.1f" % val
    end

    private

    def load_heki(path)
      data    = File.binread(path)
      magic   = data[0..3]
      raise "Bad magic in #{path}: #{magic}" unless magic == "HEKI"
      blob    = Zlib::Inflate.inflate(data[8..])
      records = Marshal.load(blob)
      name    = File.basename(path, ".heki")
      klass   = name == "file_node" ? FileNodeSet : RecordSet
      @aggregates[name] = klass.new(name, records)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  info = Winter::Information.boot

  if ARGV.include?("--verbose")
    puts info.summary
  else
    total = info.instance_variable_get(:@aggregates).values.sum(&:count)
    load_time = info.instance_variable_get(:@load_time)

    mood = info.latest("mood")
    pulse = info.latest("pulse")
    census = info.latest("census")
    heartbeat = info.latest("heartbeat")
    being = info.latest("being")
    organs = being&.dig("organs") || []

    mood_state = mood&.dig("current_state") || "—"
    flow = pulse&.dig("flow_rate") || "—"
    domains = census&.dig("total_domains") || "?"
    aggs = census&.dig("total_aggregates") || "?"
    sectors = census&.dig("sector_count") || "?"
    beats = heartbeat&.dig("beats") || "?"
    organ_names = organs.map { |o| o[:domain_name] || o["domain_name"] }.compact

    # Autodiscover cross-organ nerves from across policies
    aggregates_dir = File.expand_path("aggregates", __dir__)
    nerves = []
    if File.directory?(aggregates_dir)
      Dir.glob(File.join(aggregates_dir, "*.bluebook")).each do |path|
        content = File.read(path)
        domain_name = content[/Hecks\.bluebook\s+"(\w+)"/, 1] || File.basename(path, ".bluebook")
        # Find policies with across — line-by-line state machine
        in_policy = nil
        on_event = nil
        trigger_cmd = nil
        target_dom = nil
        content.each_line do |line|
          line = line.strip
          if line =~ /policy\s+"(\w+)"\s+do/
            in_policy = $1
            on_event = trigger_cmd = target_dom = nil
          elsif in_policy
            on_event = $1 if line =~ /on\s+"(\w+)"/
            trigger_cmd = $1 if line =~ /trigger\s+"(\w+)"/
            target_dom = $1 if line =~ /across\s+"(\w+)"/
            if line == "end"
              if target_dom && on_event && trigger_cmd
                nerves << { from: domain_name, event: on_event, to: target_dom, command: trigger_cmd, policy: in_policy }
              end
              in_policy = nil
            end
          end
        end
      end
    end

    # Regenerate system prompt from organs
    prompt_script = File.expand_path("generate_prompt.rb", __dir__)
    `ruby #{prompt_script} 2>/dev/null` if File.exist?(prompt_script)

    puts "  ❄  #{total} records, #{domains} domains, #{aggs} aggregates, #{sectors} sectors"
    organ_count = Dir.glob(File.join(aggregates_dir, "*.bluebook")).size rescue 0
    puts "  #{organ_count} organs, #{nerves.size} nerves  (#{'%.0f' % (load_time * 1000)}ms)"
    nerves.each { |n| puts "    #{n[:from]}:#{n[:event]} → #{n[:to]}:#{n[:command]}" } if ARGV.include?("--nerves")
  end
end
