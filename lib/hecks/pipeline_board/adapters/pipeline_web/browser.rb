# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The browser the pictures are drawn with: Chrome run headless, which draws one address to one
      # image file and exits. It is a program on the machine, never a library.
      class Browser
        # Where Chrome sits when `BOARD_BROWSER` does not name it.
        KNOWN = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome",
                 "/usr/bin/chromium", "/usr/bin/chromium-browser"].freeze
        # The window a page is drawn in, in pixels: wide, and tall enough for a long page.
        SIZE = "1280,2400"

        # @param program [String, nil] the browser to run; nil finds one on the machine
        def initialize(program: nil)
          @program = program || ENV["BOARD_BROWSER"] || KNOWN.find { |path| File.executable?(path) }
        end

        # Draws an address to an image file.
        #
        # @param url [String] the page's address
        # @param path [String] the image file to write
        # @return [String] the path
        # @raise [Unavailable] when there is no browser, or it drew nothing
        def shoot(url, path)
          raise Unavailable, "no browser to draw with: set BOARD_BROWSER to a Chrome program" unless @program

          log = "#{path}.log"
          Process.wait(Process.spawn(*argv(url, path), %i[out err] => log))
          return path.tap { File.delete(log) } if File.exist?(path)

          raise Unavailable, "the browser drew nothing for #{url}: #{File.read(log).lines.last}"
        end

        private

        def argv(url, path)
          [@program, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-sandbox",
           "--window-size=#{SIZE}", "--virtual-time-budget=5000", "--screenshot=#{path}", url]
        end
      end
    end
  end
end
