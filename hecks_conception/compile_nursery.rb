# compile_nursery.rb
#
# Compiles all Bluebook files in the nursery into a single compressed
# binary corpus using a custom format:
#
#   [4 bytes: string count] [newline-delimited string table]
#   [domain stream: varint-encoded refs with structural markers]
#
# All gzipped at max compression. String table deduplicates every
# repeated value. Domain IR is a flat byte stream — no JSON overhead,
# no array brackets, no key names.
#
# Markers (single byte):
#   0xFE = domain boundary
#   0xFD = aggregate boundary
#   0xFC = command boundary
#   0xFB = value object boundary
#   0xFA = policy boundary
#   0xF9 = attribute boundary
#   0xF8 = reference list
#   0xF7 = end-of-section
#   0xF6 = nil/absent
#
# Usage:
#   ruby -I../lib compile_nursery.rb
#
# Output:
#   nursery.corpus.gz

require "zlib"
require "json"
require "hecks"

NURSERY = File.join(__dir__, "nursery")
OUTPUT  = File.join(__dir__, "nursery.corpus.gz")

# --- String table with frequency-sorted indices ---
# Two-pass: first pass counts frequency, finalize sorts by frequency
# so the most common strings get the smallest varint indices.
class StringTable
  def initialize
    @freq = Hash.new(0)
    @finalized = false
    @table = {}
    @list = []
  end

  # Pass 1: count occurrences
  def count(s)
    return if s.nil?
    @freq[s.to_s] += 1
  end

  # Between passes: assign indices by descending frequency
  def finalize!
    @list = @freq.keys.sort_by { |s| -@freq[s] }
    @list.each_with_index { |s, i| @table[s] = i }
    @finalized = true
  end

  # Pass 2: look up index
  def intern(s)
    return nil if s.nil?
    s = s.to_s
    raise "call finalize! first" unless @finalized
    # Late additions get appended (shouldn't happen if pass 1 is thorough)
    unless @table.key?(s)
      @table[s] = @list.size
      @list << s
    end
    @table[s]
  end

  def to_a = @list
  def size = @list.size
end

# --- Varint encoding (protobuf-style) ---
def encode_varint(n)
  bytes = []
  loop do
    byte = n & 0x7F
    n >>= 7
    byte |= 0x80 if n > 0
    bytes << byte
    break if n == 0
  end
  bytes.pack("C*")
end

# --- Markers ---
M_DOMAIN    = 0xFE
M_AGGREGATE = 0xFD
M_COMMAND   = 0xFC
M_VO        = 0xFB
M_POLICY    = 0xFA
M_ATTR      = 0xF9
M_REFS      = 0xF8
M_END       = 0xF7
M_NIL       = 0xF6

ST = StringTable.new
STREAM = String.new(encoding: "BINARY")

def emit_marker(m)   = STREAM << [m].pack("C")
def emit_ref(idx)    = STREAM << encode_varint(idx)
def emit_nil_or_ref(v) = v.nil? ? emit_marker(M_NIL) : emit_ref(v)

def emit_attr(attr)
  emit_marker(M_ATTR)
  emit_ref(ST.intern(attr.name))
  emit_ref(ST.intern(attr.type.to_s))
  STREAM << [(attr.respond_to?(:list?) && attr.list?) ? 1 : 0].pack("C")
end

def emit_vo(vo)
  emit_marker(M_VO)
  emit_ref(ST.intern(vo.name))
  vo.attributes.each { |a| emit_attr(a) }
  emit_marker(M_END)
end

def emit_cmd(cmd)
  emit_marker(M_COMMAND)
  emit_ref(ST.intern(cmd.name))
  emit_nil_or_ref(cmd.respond_to?(:role) && cmd.role ? ST.intern(cmd.role) : nil)
  if cmd.respond_to?(:attributes)
    cmd.attributes.each { |a| emit_attr(a) }
  end
  if cmd.respond_to?(:emits) && cmd.emits
    emit_ref(ST.intern(cmd.emits))
  else
    emit_marker(M_NIL)
  end
  emit_marker(M_END)
end

def emit_policy(pol)
  emit_marker(M_POLICY)
  emit_ref(ST.intern(pol.name))
  emit_ref(ST.intern(pol.event_name))
  emit_ref(ST.intern(pol.trigger_command))
end

def emit_agg(agg)
  emit_marker(M_AGGREGATE)
  emit_ref(ST.intern(agg.name))
  # Descriptions dropped — regenerable from names, saves ~55KB in string table

  # Attributes
  agg.attributes.each { |a| emit_attr(a) }

  # Value objects
  if agg.respond_to?(:value_objects)
    agg.value_objects.each { |vo| emit_vo(vo) }
  end

  # Commands
  agg.commands.each { |c| emit_cmd(c) }

  # References
  if agg.respond_to?(:references) && !agg.references.empty?
    emit_marker(M_REFS)
    agg.references.each { |r| emit_ref(ST.intern(r.name)) }
    emit_marker(M_END)
  end

  # Aggregate-level policies
  if agg.respond_to?(:policies)
    agg.policies.each { |p| emit_policy(p) }
  end

  emit_marker(M_END)
end

def emit_domain(domain)
  emit_marker(M_DOMAIN)
  emit_ref(ST.intern(domain.name))

  domain.aggregates.each { |a| emit_agg(a) }
  domain.policies.each { |p| emit_policy(p) }

  emit_marker(M_END)
end

# --- Pass 1: count string frequencies ---
bluebooks = Dir.glob(File.join(NURSERY, "**", "*.bluebook")).sort
loaded_domains = []
errors = []

bluebooks.each do |path|
  relative = path.sub("#{NURSERY}/", "")
  begin
    Kernel.load(path)
    domain = Hecks.last_domain
    if domain
      # Validation gate: only valid domains enter the corpus
      valid, validation_errors = Hecks.validate(domain)
      unless valid
        errors << "#{relative}: REJECTED (#{validation_errors.size} errors)"
        validation_errors.each { |e| errors << "  #{e}" }
        $stderr.print "x"
        next
      end

      loaded_domains << domain
      # Count all strings
      ST.count(domain.name)
      domain.aggregates.each do |a|
        ST.count(a.name)
        a.attributes.each { |at| ST.count(at.name); ST.count(at.type.to_s) }
        a.value_objects.each do |vo|
          ST.count(vo.name)
          vo.attributes.each { |at| ST.count(at.name); ST.count(at.type.to_s) }
        end if a.respond_to?(:value_objects)
        a.commands.each do |c|
          ST.count(c.name)
          ST.count(c.role) if c.respond_to?(:role) && c.role
          c.attributes.each { |at| ST.count(at.name); ST.count(at.type.to_s) } if c.respond_to?(:attributes)
          ST.count(c.emits) if c.respond_to?(:emits) && c.emits
        end
        a.references.each { |r| ST.count(r.name) } if a.respond_to?(:references)
        a.policies.each do |p|
          ST.count(p.name); ST.count(p.event_name); ST.count(p.trigger_command)
        end if a.respond_to?(:policies)
      end
      domain.policies.each do |p|
        ST.count(p.name); ST.count(p.event_name); ST.count(p.trigger_command)
      end
    else
      errors << "#{relative}: no domain returned"
    end
  rescue => e
    errors << "#{relative}: #{e.message}"
  end
end

ST.finalize!
$stderr.print "Pass 1: #{loaded_domains.size} domains, #{ST.size} strings\n"

# --- Pass 2: encode to binary stream ---
count = 0

loaded_domains.each do |domain|
  emit_domain(domain)
  count += 1
  $stderr.print "."
end
$stderr.puts

# --- Pack: header + string table + domain stream ---
st_blob = ST.to_a.join("\n").encode("UTF-8").b
header = [ST.size, st_blob.bytesize, STREAM.bytesize].pack("N3")
full_blob = String.new(encoding: "BINARY")
full_blob << header << st_blob << STREAM

# Gzip max
Zlib::GzipWriter.open(OUTPUT, Zlib::BEST_COMPRESSION) { |gz| gz.write(full_blob) }

# --- Report ---
gz_size = File.size(OUTPUT)
raw_size = bluebooks.sum { |f| File.size(f) }
naive_json_size = File.size(File.join(__dir__, "..", "hecks_body", "corpus.json")) rescue raw_size

puts "Compiled #{count}/#{bluebooks.size} domains"
puts "  String table:    #{ST.size} entries (#{(st_blob.bytesize / 1024.0).round(1)} KB)"
puts "  Domain stream:   #{(STREAM.bytesize / 1024.0).round(1)} KB"
puts "  Uncompressed:    #{((header.bytesize + st_blob.bytesize + STREAM.bytesize) / 1024.0).round(1)} KB"
puts "  Gzipped:         #{(gz_size / 1024.0).round(1)} KB"
puts "  Raw .bluebook:   #{(raw_size / 1024.0).round(1)} KB"
puts "  vs raw source:   #{((1.0 - gz_size.to_f / raw_size) * 100).round(1)}% smaller"
puts "  vs naive JSON:   #{((1.0 - gz_size.to_f / naive_json_size) * 100).round(1)}% smaller"
puts "  Output:          #{OUTPUT}"

unless errors.empty?
  puts "\nErrors (#{errors.size}):"
  errors.each { |e| puts "  #{e}" }
end
