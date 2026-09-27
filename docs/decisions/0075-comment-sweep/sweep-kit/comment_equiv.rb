#!/usr/bin/env ruby
# usage: comment_equiv.rb BASE_REF path...
# Prints "OK path" or "FAIL path: reason"; exits 1 if any file fails.
require "ripper"
require "yaml"
require "date"
require "open3"

RUBY_KEEP = /\A#\s*(frozen_string_literal|encoding|coding|warn_indent|shareable_constant_value|steep|typed)\s*:|\A#\s*rubocop\s*:|\A#\s*:nocov:|\A#\s*simplecov\s*:|\A#!/
HASH_KEEP = /\A\s*#(!|\s*(shellcheck|yamllint|syntax=|escape=|rubocop\s*:|frozen_string_literal\s*:))/
RUBY_EXT = %w[.rb .rake .gemspec .ru .bluebook .hecksagon .world .adapter .port .behaviors .behaviours].freeze
RUBY_NAMES = %w[Rakefile Gemfile Guardfile Capfile].freeze

def base(ref, path)
  out, st = Open3.capture2("git", "show", "#{ref}:#{path}", err: File::NULL)
  st.success? ? out : nil
end

def kind(path, src)
  ext = File.extname(path)
  return :rust if ext == ".rs"
  return :ruby if RUBY_EXT.include?(ext) || RUBY_NAMES.include?(File.basename(path))
  return :yaml if %w[.yml .yaml].include?(ext)
  return :hash if ext == ".toml" || ext == ".sh"
  first = src.lines.first.to_s
  return :ruby if first =~ /\A#!.*ruby/
  :hash
end

def ruby_tokens(src)
  raise "does not parse" unless Ripper.sexp(src)
  drop = %i[on_comment on_sp on_nl on_ignored_nl on_embdoc_beg on_embdoc on_embdoc_end on_ignored_sp]
  Ripper.lex(src).filter_map do |(_, type, tok, _)|
    next tok.strip if type == :on_comment && tok =~ RUBY_KEEP
    next if drop.include?(type)
    tok
  end
end

def rust_strip(src)
  out = +""
  i = 0
  n = src.length
  while i < n
    c = src[i]
    two = src[i, 2]
    if two == "//"
      j = src.index("\n", i) || n
      line = src[i...j]
      out << " " << line.strip << " " if line =~ %r{\A//\s*TMPL:}
      out << " "
      i = j
    elsif two == "/*"
      depth = 1
      i += 2
      while i < n && depth > 0
        if src[i, 2] == "/*" then depth += 1; i += 2
        elsif src[i, 2] == "*/" then depth -= 1; i += 2
        else i += 1
        end
      end
      out << " "
    elsif c == "r" && (i.zero? || src[i - 1] !~ /[A-Za-z0-9_]/) && (rm = src[i..].match(/\Ar(#*)"/))
      hashes = rm[1]
      close = "\"" + hashes
      k = src.index(close, i + 2 + hashes.length) or raise "unterminated raw string"
      out << src[i...(k + close.length)]
      i = k + close.length
    elsif c == "\""
      k = i + 1
      k += (src[k] == "\\" ? 2 : 1) while k < n && src[k] != "\""
      out << src[i..k]
      i = k + 1
    elsif c == "'"
      if src[i..] =~ /\A'(\\.[^']*|[^\\'])'/
        m = Regexp.last_match(0)
        out << m
        i += m.length
      else
        out << c
        i += 1
      end
    else
      out << c
      i += 1
    end
  end
  out.gsub(/\s+/, " ").strip
end

def hash_lines(src)
  src.lines.reject { |l| l =~ /\A\s*#/ && l !~ HASH_KEEP }.map(&:rstrip).reject(&:empty?)
end

def check(ref, path)
  return "symlink, skipped" if File.symlink?(path)
  old = base(ref, path)
  return "new file at base, skipped" if old.nil?
  cur = File.read(path)
  case kind(path, old)
  when :ruby
    return "non-comment tokens differ" unless ruby_tokens(old) == ruby_tokens(cur)
  when :rust
    return "non-comment tokens differ" unless rust_strip(old) == rust_strip(cur)
  when :yaml
    load = ->(s) { YAML.safe_load(s, aliases: true, permitted_classes: [Date, Time, Symbol]) }
    return "parsed YAML differs" unless load.(old) == load.(cur)
    return "non-comment lines differ" unless hash_lines(old) == hash_lines(cur)
  else
    return "non-comment lines differ" unless hash_lines(old) == hash_lines(cur)
    if old.lines.first.to_s =~ /\A#!.*(bash|sh)\b/
      _, st = Open3.capture2("bash", "-n", path, err: File::NULL)
      return "bash -n fails" unless st.success?
    end
  end
  nil
end

ref = ARGV.shift or abort "usage: comment_equiv.rb BASE_REF path... | @listfile"
paths = ARGV.flat_map { |a| a.start_with?("@") ? File.readlines(a[1..], chomp: true).reject(&:empty?) : [a] }
bad = 0
paths.each do |path|
  begin
    err = check(ref, path)
  rescue StandardError => e
    err = "checker error: #{e.class}: #{e.message}"
  end
  if err.nil? then puts "OK #{path}"
  else puts "FAIL #{path}: #{err}"; bad += 1
  end
end
exit(bad.zero? ? 0 : 1)
