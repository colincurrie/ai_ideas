# frozen_string_literal: true

require_relative "font"

module FakeSign
  # Turns a decoded text file into a 16x135 grid of pixel colour codes
  # (0 off, 1 red, 2 green, 3 yellow) - the same codes the Dots wire format
  # uses, so the preview and a picture speak the same language.
  #
  # Fidelity, stated plainly: layout and colour are modelled, glyph shapes
  # are approximate (see Font), and effects are not animated - each file
  # renders as the still frame it would settle into. Enough to see which
  # files get called and where things land; not enough to answer "will this
  # fit".
  class Renderer
    WIDTH = 135
    HEIGHT = 16

    # Section 21's colour table, collapsed to what the hardware can emit.
    SOLID_COLOURS = {
      "1" => 1, "4" => 1,                       # red, dim red
      "2" => 2, "5" => 2,                       # green, dim green
      "3" => 3, "6" => 3, "7" => 3, "8" => 3    # amber/brown/orange/yellow
    }.freeze
    # Everything above "8" is a rainbow, mix, stripe or auto mode: a
    # per-character or per-column cycle rather than one colour. Cycling
    # red/yellow/green is a stand-in, not a reproduction.
    CYCLE = [1, 3, 2].freeze

    def initialize(sign)
      @sign = sign
    end

    # A frame per text file that has content, in run-sequence order.
    def frames
      @sign.run_sequence.map do |label|
        { label: label, pixels: render_text_file(@sign.files[label][:content]) }
      end
    end

    def render_text_file(content)
      grid = Array.new(HEIGHT) { Array.new(WIDTH, 0) }
      position = content[:position] || :fill
      cursor = 0
      colour = "1"
      cycling = false
      column_index = 0

      (content[:content] || []).each do |run|
        case run[:type]
        when :colour
          colour = run[:value]
          cycling = !SOLID_COLOURS.key?(colour)
        when :text
          run[:value].each_char do |char|
            cursor, column_index = draw_char(grid, char, cursor, position, colour, cycling, column_index)
          end
        when :call_string
          string = @sign.files[run[:label]]
          text = string && string[:updated] ? string_text(string) : ""
          text.each_char do |char|
            cursor, column_index = draw_char(grid, char, cursor, position, colour, cycling, column_index)
          end
        when :call_dots
          cursor = draw_picture(grid, run[:label], cursor, position)
        end
        break if cursor >= WIDTH
      end

      grid
    end

    private

    def string_text(file)
      (file[:content][:content] || []).select { |r| r[:type] == :text }.map { |r| r[:value] }.join
    end

    def draw_char(grid, char, cursor, position, colour, cycling, column_index)
      top = text_top(position)
      Font.glyph(char).each_with_index do |mask, dx|
        column = cursor + dx
        next if column >= WIDTH

        Font::HEIGHT.times do |row|
          next unless mask[row] == 1

          grid[top + row][column] = cycling ? CYCLE[column_index % CYCLE.size] : SOLID_COLOURS.fetch(colour, 1)
        end
      end
      [cursor + Font::ADVANCE, column_index + 1]
    end

    # Section 17: 7-high text sits at the top line, bottom line, or centred
    # for Middle. Fill assembles two lines; the preview draws the first.
    def text_top(position)
      case position
      when :top, :fill then 0
      when :bottom then HEIGHT - Font::HEIGHT
      else (HEIGHT - Font::HEIGHT) / 2 # middle
      end
    end

    # Section 13's placement table: for 7-high modes a picture up to 8 high
    # shows "all lines from bottom", except Middle where it is centred.
    def draw_picture(grid, label, cursor, position)
      file = @sign.files[label]
      return cursor unless file && file[:type] == :dots && file[:updated]

      rows = file[:content][:rows] || []
      height = rows.size
      width = file[:content][:width].to_i
      top = picture_top(height, position)

      rows.each_with_index do |row, y|
        row.each_char.with_index do |pixel, x|
          column = cursor + x
          next if column >= WIDTH

          target = top + y
          next if target.negative? || target >= HEIGHT

          code = pixel.to_i
          # Section 13's pixel table: 4-8 collapse onto the three colours
          # this hardware can show.
          code = { 4 => 1, 5 => 2, 6 => 3, 7 => 3, 8 => 3 }.fetch(code, code)
          grid[target][column] = code
        end
      end

      cursor + width
    end

    def picture_top(height, position)
      window = position == :middle ? HEIGHT : (position == :bottom ? HEIGHT : 8)
      case position
      when :middle then [(HEIGHT - height) / 2, 0].max
      when :bottom then HEIGHT - height
      else [window - height, 0].max # "all lines from bottom" of the 8-row window
      end
    end
  end
end
