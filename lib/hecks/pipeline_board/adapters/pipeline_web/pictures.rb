# frozen_string_literal: true

require "fileutils"
require_relative "browser"

module Hecks
  module Adapters
    module PipelineBoard
      # Draws every page of a board to an image, from the board it is given: it opens the board on a
      # free loopback port, asks the browser for each page and stops the board.
      class Pictures
        # Each page's path and the name its image carries.
        PAGES = { "/" => "board", "/events" => "events", "/wiring" => "wiring", "/sequence" => "sequence",
                  "/agents" => "agents", "/plan" => "plan", "/diagrams" => "diagrams", "/ci" => "ci",
                  "/settings" => "settings" }.freeze

        # @param app [PipelineWeb] the board to draw
        # @param browser [#shoot] draws an address to an image file
        def initialize(app:, browser: nil)
          @app = app
          @browser = browser || Browser.new
        end

        # @param state [String] `live` or `bad_day`, the first part of each image's name
        # @param into [String] the directory the images are written to
        # @return [Array<String>] the image files, one per page
        def draw(state:, into:)
          FileUtils.mkdir_p(into)
          server = @app.open_at(0)
          PAGES.map { |path, name| @browser.shoot(address(server, path), File.join(into, "#{state}-#{name}.png")) }
        ensure
          server&.stop
        end

        private

        def address(server, path) = "http://#{server.address}:#{server.port}#{path}"
      end
    end
  end
end
