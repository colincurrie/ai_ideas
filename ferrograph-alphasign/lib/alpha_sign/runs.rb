# Encodes a message built from multiple styled "runs" - segments of text
# each with their own optional color and font - into a single string with
# the appropriate control codes embedded between segments. This is how a
# rich-text compose UI (select some text, apply a color/font) maps onto the
# wire format: color (0x1C) and font (0x1A) are per-character attributes
# that persist until changed, so a new control code is only emitted when a
# run's color or font actually differs from the previous run's.
#
# Position, display mode/effect and speed are NOT part of a run - the
# protocol only allows those to be set once, at the start of the whole
# message (see AlphaSign::TextFile).
module AlphaSign
  module Runs
    # +runs+ is an array of hashes/objects responding to [:text], [:color]
    # and [:font] (color and font are optional; unset/nil leaves the
    # previous run's color or font in effect on the sign).
    def self.encode(runs)
      current_color = nil
      current_font = nil

      Array(runs).each_with_object(+"") do |run, out|
        text = run[:text].to_s
        next if text.empty?

        if run[:color]
          code = Colors.lookup(run[:color])
          if code != current_color
            out << code
            current_color = code
          end
        end

        if run[:font]
          code = CharSets.lookup(run[:font])
          if code != current_font
            out << code
            current_font = code
          end
        end

        out << text
      end
    end
  end
end
