# frozen_string_literal: true

module Vkit
  module Core
    module Ansi
      COLORS = {
        red:    31,
        green:  32,
        yellow: 33,
        blue:   34,
        gray:   90
      }.freeze

      def self.color(text, color)
        return text unless $stdout.tty?

        code = COLORS[color]
        "\e[#{code}m#{text}\e[0m"
      end

      def self.green(text)  = color(text, :green)
      def self.red(text)    = color(text, :red)
      def self.yellow(text) = color(text, :yellow)
      def self.blue(text)   = color(text, :blue)
      def self.gray(text)   = color(text, :gray)
    end
  end
end
