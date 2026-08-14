require_relative "doctest"

# WHICH MARKDOWN RUNS, AND WHO OWNS WHICH NAME.
#
# Two sets of executable documentation now share one process: the guides,
# which are narratives, and the DSL reference, which is one page per
# context and one runnable example per word. They are separate specs
# because they fail for different reasons and a reader chasing a red
# example should land in the right one — but they are ONE namespace.
#
# `Facade::Surface.install` (lib/hecksagain/facade/surface.rb) installs a
# chapter's name AND every one of its aggregates' bare names onto Object,
# and nothing ever uninstalls them. Two files inventing the same chapter
# would therefore rebind whichever booted last, and under randomized spec
# order that is a coin flip rather than a failure. So the claim is
# checked across the union, once, before anything boots.
module DoctestNames
  ROOT = InMemoryDomain::ROOT

  module_function

  # AUTHORING.md is the contract for writing these, and index.md is a
  # generated table of contents — neither is a document with claims of
  # its own to back.
  def guides
    (Dir.glob(File.join(ROOT, "docs/guides/*.md")).sort -
     [File.join(ROOT, "docs/guides/AUTHORING.md"),
      File.join(ROOT, "docs/guides/index.md")]) +
      [File.join(ROOT, "README.md")]
  end

  def reference
    Dir.glob(File.join(ROOT, "docs/reference/*.md")).sort -
      [File.join(ROOT, "docs/reference/index.md")]
  end

  def all = guides + reference

  # Every chapter name each document INVENTS, keyed by path. A document
  # that instead `Kernel.load`s a real corpus file never writes that
  # chapter's own `Hecks.bluebook` line itself, so it claims nothing and
  # any number of documents may share one corpus example safely — see
  # `Doctest.declared_domains` for why that is deliberate. It is also the
  # reason the reference pages prefer loading the corpus: 105 invented
  # chapters would be 105 names to keep distinct, and the corpus is
  # already the honest thing to document a shipped language with.
  def claims
    all.to_h { |path| [path, Doctest.declared_domains(Doctest.parse(path))] }
  end

  # Returns a list of sentences, empty when nothing collides.
  def collisions
    owners = {}
    claims.flat_map do |path, domains|
      domains.filter_map do |domain|
        owner = owners[domain]
        owners[domain] = path unless owner
        next unless owner

        "#{relative(path)} declares #{domain.inspect}, already declared by #{relative(owner)} " \
          "— a chapter name is claimed once across the guides and the reference together"
      end
    end
  end

  def relative(path) = path.delete_prefix("#{ROOT}/")
end
