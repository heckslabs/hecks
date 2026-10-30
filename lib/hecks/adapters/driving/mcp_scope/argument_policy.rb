require_relative "../../../runtime/errors"

module Hecks
  module Adapters
    module Driving
      class McpScope
        # What a restricted server lets an argument say: a denied name is refused, a path must
        # resolve
        # inside the root with symlinks followed, and a git ref must be a plain name.
        module ArgumentPolicy
          module_function

          # Checks every argument in `args`, nested or not, and refuses the first one the policy
          # forbids.
          #
          # Read-only questions whose `path` names one file of the checkout. `path` is denied by name
          # for every other command, since it can name a place to write; these reads are allowed it,
          # and admit_path! still confines it to the checkout.
          READ_PATH_QUESTIONS = %w[inspection_run.read_source inspection_run.outline].freeze

          # The line window those reads take: plain numbers that name no place, so they pass.
          READ_WINDOW_ARGUMENTS = %w[from to top].freeze

          # @param args [Hash, Array, nil] the arguments as the caller gave them
          # @param label [String] how the server describes its mode, for the refusal
          # @param question [String, nil] the query asked, when the arguments are a question's
          # @raise [Runtime::TypeMismatch] on the first argument refused
          def admit!(args, label, question = nil)
            read_question = READ_PATH_QUESTIONS.include?(snake_question(question))
            each_argument(args) do |name, value|
              if read_question && READ_WINDOW_ARGUMENTS.include?(name)
                next
              end
              if name == "path" && read_question
                admit_path!(name, value, label)
                next
              end
              if DENIED_ARGUMENTS.include?(name)
                refuse!(name, label, "never passes it on: it names a host, a binary, an output or a change of state")
              end
              admit_path!(name, value, label) if PATH_ARGUMENTS.include?(name)
              admit_ref!(name, value, label) if REF_ARGUMENTS.include?(name)
            end
          end

          # Yields every argument name with its value, descending into nested objects and lists, so
          # `{"file" => {"value" => "x"}}` is checked the way `{"file" => "x"}` is.
          def each_argument(args, &visit)
            case args
            when Hash
              args.each do |name, value|
                yield(name.to_s, value)
                each_argument(value, &visit)
              end
            when Array
              args.each { |item| each_argument(item, &visit) }
            end
          end

          # A value written as an object of one field (`{"value" => "x"}`) is that field's value.
          def scalar(value)
            return value unless value.is_a?(Hash)

            value.fetch("value") { value.fetch(:value, value) }
          end

          # The question as `Aggregate.query` or `aggregate_run.query` names it, in the snake form
          # `READ_PATH_QUESTIONS` uses.
          def snake_question(question)
            question.to_s.split(".").map { |part| part.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase }.join(".")
          end

          def refuse!(name, label, why)
            raise Runtime::TypeMismatch, "argument: #{name.inspect} is refused: this server runs in #{label} and #{why}"
          end

          def admit_path!(name, value, label)
            Array(scalar(value)).flat_map { |item| item.to_s.split(",") }.reject(&:empty?).each do |path|
              next if !path.include?(":") && inside_root?(path)

              refuse!(name, label, "passes a path only when it resolves inside #{Storehouse::BOOT_ROOT} " \
                                   "and holds no colon: #{path.inspect}")
            end
          end

          def admit_ref!(name, value, label)
            ref = scalar(value).to_s
            return if ref.match?(PLAIN_REF) && !ref.include?("..")

            refuse!(name, label, "passes only a plain git ref: #{ref.inspect}")
          end

          def inside_root?(path)
            root = resolve_real(Storehouse::BOOT_ROOT)
            resolved = resolve_real(File.expand_path(path, Storehouse::BOOT_ROOT))
            resolved == root || resolved.start_with?("#{root}#{File::SEPARATOR}")
          end

          # The real path of `path`, symlinks followed: of the whole path when it exists, else of
          # its
          # deepest existing parent with the missing names put back, so a link above a file that
          # does
          # not exist yet still shows where the file would land.
          def resolve_real(path)
            missing = []
            current = File.expand_path(path)
            until File.exist?(current)
              parent = File.dirname(current)
              break if parent == current

              missing.unshift(File.basename(current))
              current = parent
            end
            File.join(File.realpath(current), *missing)
          end
        end
      end
    end
  end
end
