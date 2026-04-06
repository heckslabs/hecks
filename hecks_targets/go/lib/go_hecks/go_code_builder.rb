# GoHecks::GoCodeBuilder
#
# Fluent builder for generating Go source files. Encapsulates the
# recurring patterns shared by all Go generators: package declarations,
# import blocks, struct definitions, receiver methods, and functions.
#
#   b = GoCodeBuilder.new("domain")
#   b.imports("time", "fmt")
#   b.struct("Pizza") do |s|
#     s.field("Name", "string", json: "name")
#   end
#   b.receiver("Pizza", "Validate", "error") do |m|
#     m.line('return nil')
#   end
#   b.to_s  # => Go source string
#
module GoHecks
  class GoCodeBuilder
    def initialize(package)
      @package = package
      @sections = []
      @import_set = []
    end

    # Add one or more import paths. Duplicates are ignored.
    def imports(*paths)
      paths.each { |p| @import_set << p unless @import_set.include?(p) }
      self
    end

    # Add a blank line between sections.
    def blank
      @sections << ""
      self
    end

    # Add a raw line of Go code.
    def line(text)
      @sections << text
      self
    end

    # Add a raw block of lines.
    def lines(arr)
      @sections.concat(arr)
      self
    end

    # Build a struct definition. Yields a StructBuilder for adding fields.
    def struct(name)
      sb = StructBuilder.new(name)
      yield sb if block_given?
      @sections.concat(sb.to_lines)
      @sections << ""
      self
    end

    # Build a const block. Yields a ConstBuilder for adding constants.
    def const_block
      cb = ConstBuilder.new
      yield cb
      @sections.concat(cb.to_lines)
      @sections << ""
      self
    end

    # Build a receiver method: func (recv *Type) Name() ReturnType { ... }
    # method_name can include params: "Validate" or "ValidTransition(target string)"
    def receiver(type_name, method_name, return_type, pointer: true)
      recv_var = type_name[0].downcase
      recv = pointer ? "*#{type_name}" : type_name
      qualified = method_name.include?("(") ? method_name : "#{method_name}()"
      mb = MethodBuilder.new("(#{recv_var} #{recv}) #{qualified}", return_type)
      yield mb if block_given?
      @sections.concat(mb.to_lines)
      self
    end

    # Build a standalone function: func Name(params) ReturnType { ... }
    # Pass the full signature (with parens) as name when params is nil.
    def func(name, params, return_type)
      if params.nil?
        sig = name
      elsif params.empty?
        sig = "#{name}()"
      else
        sig = "#{name}(#{params})"
      end
      mb = MethodBuilder.new(sig, return_type)
      yield mb if block_given?
      @sections.concat(mb.to_lines)
      self
    end

    # Build a one-line receiver method.
    def one_liner(type_name, method_name, return_type, body, pointer: true)
      recv_var = type_name[0].downcase
      recv = pointer ? "*#{type_name}" : type_name
      @sections << "func (#{recv_var} #{recv}) #{method_name}() #{return_type} { #{body} }"
      self
    end

    # Render the complete Go source file.
    def to_s
      out = []
      out << "package #{@package}"
      out << ""
      unless @import_set.empty?
        if @import_set.size == 1
          out << "import #{@import_set.first}"
        else
          out << "import ("
          @import_set.each { |i| out << "\t#{i}" }
          out << ")"
        end
        out << ""
      end
      out.concat(@sections)
      out.join("\n") + "\n"
    end

    # Nested builder for struct fields.
    class StructBuilder
      def initialize(name)
        @name = name
        @fields = []
      end

      def field(go_name, go_type, json: nil)
        if json
          @fields << "\t#{go_name} #{go_type} `json:\"#{json}\"`"
        else
          @fields << "\t#{go_name} #{go_type}"
        end
        self
      end

      def to_lines
        if @fields.empty?
          ["type #{@name} struct{}"]
        else
          ["type #{@name} struct {"] + @fields + ["}"]
        end
      end
    end

    # Nested builder for const blocks.
    class ConstBuilder
      def initialize
        @entries = []
      end

      def value(name, val)
        @entries << "\t#{name} = #{val}"
        self
      end

      def to_lines
        ["const ("] + @entries + [")"]
      end
    end

    # Nested builder for method/function bodies.
    class MethodBuilder
      def initialize(signature, return_type)
        @signature = signature
        @return_type = return_type
        @body = []
      end

      def line(text)
        @body << "\t#{text}"
        self
      end

      def lines(arr)
        arr.each { |l| @body << "\t#{l}" }
        self
      end

      def to_lines
        rt = @return_type && !@return_type.empty? ? " #{@return_type}" : ""
        ["func #{@signature}#{rt} {"] + @body + ["}"]
      end
    end
  end
end
