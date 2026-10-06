module Hecks
  module Projections
    module Deploy
      # Fills the `@@name@@` markers of a text file under `templates/`: the CloudFormation, Makefile
      # and shell text a deploy target emits lives there, and Ruby supplies each marker's value.
      #
      # A value is spliced as it is, so a multi-line value brings its own indentation. Every marker
      # must be given a value; one left unfilled raises rather than reaching the emitted file.
      module TextTemplate
        DIR = File.join(__dir__, "templates").freeze
        MARKER = /@@(\w+)@@/

        module_function

        # @param name [String] the template's path under `templates/`, e.g. `"preview/header.tmpl"`
        # @param values [Hash{Symbol => #to_s}] each marker's replacement
        # @return [String] the template text with every marker replaced
        # @raise [KeyError] if the template holds a marker `values` does not name
        def render(name, **values)
          File.read(File.join(DIR, name)).gsub(MARKER) { values.fetch(Regexp.last_match(1).to_sym).to_s }
        end

        # Fills a template from an object that answers each marker's name.
        #
        # @param name [String] the template's path under `templates/`
        # @param source [Object] answers a public method for every marker the template holds
        # @return [String] the template text with every marker replaced
        # @raise [NoMethodError] if the template holds a marker `source` does not answer
        def render_from(name, source)
          File.read(File.join(DIR, name)).gsub(MARKER) { source.public_send(Regexp.last_match(1)).to_s }
        end
      end
    end
  end
end
