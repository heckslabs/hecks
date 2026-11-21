# frozen_string_literal: true

require "timeout"

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
        # Milliseconds a page is given to settle before it is drawn; a page that streams never goes
        # idle, so the browser is told how long to wait.
        SETTLE = 4000
        # Seconds the browser may take to draw one page.
        SECONDS = 90

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
          run(argv(url, path), log)
          return path.tap { File.delete(log) } if File.exist?(path)

          raise Unavailable, "the browser drew nothing for #{url}: #{File.read(log).lines.last}"
        end

        private

        # Runs the browser with no input, its output in a log, and ends it when it takes too long.
        def run(argv, log)
          pid = Process.spawn(*argv, in: File::NULL, %i[out err] => log)
          Timeout.timeout(SECONDS) { Process.wait(pid) }
        rescue Timeout::Error
          Process.kill("KILL", pid)
          Process.wait(pid)
        end

        def argv(url, path)
          [@program, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-sandbox",
           "--window-size=#{SIZE}", "--timeout=#{SETTLE}", "--screenshot=#{path}", url]
        end
      end
    end
  end
end
