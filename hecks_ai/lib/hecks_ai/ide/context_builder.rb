# Hecks::AI::IDE::ContextBuilder
#
# Builds project context JSON for the sidebar and Claude prompts.
# Reads git branch, discovers key files, and lists usage docs.
#
#   ctx = ContextBuilder.new("/path/to/project")
#   ctx.build  # => { branch: "main", key_files: [...], ... }
#
module Hecks
  module AI
    module IDE
      class ContextBuilder
        def initialize(project_dir)
          @dir = project_dir
        end

        def build
          branch = `git -C #{@dir} rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
          story = branch[/hec-(\d+)/i] ? "HEC-#{$1}" : nil
          status = `git -C #{@dir} status --short 2>/dev/null`.strip
          commits = `git -C #{@dir} log --oneline -5 2>/dev/null`.strip

          {
            branch: branch, story: story,
            key_files: key_files, docs: docs.first(12),
            git_status: status.empty? ? "clean" : status,
            recent_commits: commits
          }
        end

        private

        def key_files
          files = []
          add_if_exists(files, "CLAUDE.md", "Project rules")
          add_if_exists(files, "FEATURES.md", "Feature list")
          Dir[File.join(@dir, "*Bluebook")].each { |f| files << { path: rel(f), label: "Domain DSL" } }
          Dir[File.join(@dir, "bluebook", "*Bluebook")].each { |f| files << { path: rel(f), label: "Domain DSL" } }
          Dir[File.join(@dir, "*Hecksagon")].each { |f| files << { path: rel(f), label: "Hecksagon DSL" } }
          files
        end

        def docs
          dir = File.join(@dir, "docs", "usage")
          return [] unless File.directory?(dir)
          Dir[File.join(dir, "*.md")].sort.map do |f|
            { path: "docs/usage/#{File.basename(f)}", label: File.basename(f, ".md").tr("_", " ") }
          end
        end

        def add_if_exists(list, name, label)
          list << { path: name, label: label } if File.exist?(File.join(@dir, name))
        end

        def rel(path)
          path.sub("#{@dir}/", "")
        end
      end
    end
  end
end
