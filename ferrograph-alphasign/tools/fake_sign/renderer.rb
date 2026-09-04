# frozen_string_literal: true

require_relative "font"
require_relative "timings"

module FakeSign
  # Composes a text file into a bitmap of pixel colour codes (0 off, 1 red,
  # 2 green, 3 yellow - the same codes the Dots wire format uses).
  #
  # The bitmap is as wide as the message needs, NOT clipped to the display.
  # That's what lets an effect move it: a Rotate travels a 400-column
  # message across a 135-column window, and the window maths belongs with
  # the animation rather than here.
  #
  # Fidelity, stated plainly: layout, colour and geometry are modelled;
  # glyph shapes are approximate (see font.rb); the decorative extended
  # effects are impressions rather than reproductions; and every duration
  # except the inter-frame pause is an estimate (see timings.rb).
  class Renderer
    WIDTH = 135
    HEIGHT = 16

    # Section 21's colour table, collapsed to what the hardware can emit.
    SOLID_COLOURS = {
      "1" => 1, "4" => 1,                       # red, dim red
      "2" => 2, "5" => 2,                       # green, dim green
      "3" => 3, "6" => 3, "7" => 3, "8" => 3    # amber/brown/orange/yellow
    }.freeze
    # Above "8" the codes are rainbows, mixes, stripes and auto modes - a
    # cycle rather than one colour. Cycling red/yellow/green per character
    # is a stand-in for their character, not a reproduction.
    CYCLE = [1, 3, 2].freeze

    def initialize(sign)
      @sign = sign
    end

    def frames
      @sign.run_sequence.map { |label| frame_for(label) }
    end

    def frame_for(label)
      content = @sign.files[label][:content]
      effect = Effects.lookup(content[:effect], content[:extended_effect])
      canvas = compose(content)

      transition = Timings::TRANSITION_SECONDS
      transition *= Timings::SLOW_TRANSITION_MULTIPLIER if effect[:slow]

      {
        label: label,
        position: content[:position] || :fill,
        effect_code: content[:effect],
        motion: effect[:motion],
        description: effect[:description],
        approximated: Effects::APPROXIMATED.include?(effect[:motion]),
        pause: pause_for(content),
        transition: transition,
        canvas: { width: canvas.first.size, height: HEIGHT, pixels: canvas }
      }
    end

    private

    # A speed control code applies to the whole file and persists until
    # changed (section 26), so the first one in the content wins.
    def pause_for(content)
      run = (content[:content] || []).find { |r| r[:type] == :speed || r[:type] == :no_hold }
      return Timings::DEFAULT_PAUSE unless run
      return Timings::NO_HOLD_SECONDS if run[:type] == :no_hold

      Timings::SPEED_PAUSES.fetch((0x14 + run[:value]).chr, Timings::DEFAULT_PAUSE)
    end

    # Lays the message out left to right, growing the bitmap as needed, and
    # pads to at least the display width so a static effect has a full
    # frame to show.
    def compose(content)
      position = content[:position] || :fill
      columns = [] # each entry is a column: HEIGHT colour codes
      colour = "1"
      cycling = false
      character_index = 0

      (content[:content] || []).each do |run|
        case run[:type]
        when :colour
          colour = run[:value]
          cycling = !SOLID_COLOURS.key?(colour)
        when :text
          run[:value].each_char do |char|
            append_char(columns, char, position, colour, cycling, character_index)
            character_index += 1
          end
        when :call_string
          string = @sign.files[run[:label]]
          next unless string && string[:type] == :string && string[:updated]

          string_text(string).each_char do |char|
            append_char(columns, char, position, colour, cycling, character_index)
            character_index += 1
          end
        when :call_dots
          append_picture(columns, run[:label], position)
        end
      end

      columns << blank_column while columns.size < WIDTH
      transpose(columns)
    end

    def blank_column
      Array.new(HEIGHT, 0)
    end

    def string_text(file)
      (file[:content][:content] || []).select { |r| r[:type] == :text }.map { |r| r[:value] }.join
    end

    def append_char(columns, char, position, colour, cycling, character_index)
      top = text_top(position)
      Font.glyph(char).each do |mask|
        column = blank_column
        Font::HEIGHT.times do |row|
          next unless mask[row] == 1

          column[top + row] = cycling ? CYCLE[character_index % CYCLE.size] : SOLID_COLOURS.fetch(colour, 1)
        end
        columns << column
      end
      columns << blank_column # inter-character spacing
    end

    # Section 13: for 7-high modes a picture up to 8 high shows "all lines
    # from bottom", except Middle where it is centred.
    def append_picture(columns, label, position)
      file = @sign.files[label]
      return unless file && file[:type] == :dots && file[:updated]

      rows = file[:content][:rows] || []
      top = picture_top(rows.size, position)

      (file[:content][:width] || 0).times do |x|
        column = blank_column
        rows.each_with_index do |row, y|
          target = top + y
          next if target.negative? || target >= HEIGHT

          code = row[x].to_i
          # Section 13: codes 4-8 collapse onto the three colours this
          # hardware can show.
          column[target] = { 4 => 1, 5 => 2, 6 => 3, 7 => 3, 8 => 3 }.fetch(code, code)
        end
        columns << column
      end
    end

    # Section 17.
    def text_top(position)
      case position
      when :top, :fill then 0
      when :bottom then HEIGHT - Font::HEIGHT
      else (HEIGHT - Font::HEIGHT) / 2 # middle
      end
    end

    def picture_top(height, position)
      case position
      when :middle then [(HEIGHT - height) / 2, 0].max
      when :bottom then HEIGHT - height
      else [8 - height, 0].max # "all lines from bottom" of the 8-row window
      end
    end

    def transpose(columns)
      Array.new(HEIGHT) { |row| columns.map { |column| column[row] } }
    end
  end
end
