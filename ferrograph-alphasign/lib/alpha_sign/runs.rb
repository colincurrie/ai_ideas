# Encodes a TEXT file's content from a list of "runs" - the pieces a
# compose UI produces - into the wire format.
#
# A run is one of:
#
#   {text: "SALE", color: "red", font: "large_fancy"}  - literal text
#   {type: "string", label: "1"}                        - call a String file
#   {type: "image",  label: "P"}                        - call a Dots file
#
# Colour (0x1C) and font (0x1A) are per-character attributes that persist
# until changed, so a new control code is only emitted when a run's colour
# or font actually differs from the previous run's.
#
# The call runs matter architecturally: String and Dots Picture files are
# never displayed on their own. Writing one only stores it in memory - it
# reaches the display solely because a TEXT file in the run sequence calls
# it at some point in its content. See docs/xdf-firmware-notes.md.
#
# Position, display mode/effect and speed are NOT part of a run - the
# protocol only allows those to be set once, at the start of the whole
# message (see AlphaSign::TextFile).
module AlphaSign
  module Runs
    def self.encode(runs)
      current_color = nil
      current_font = nil

      Array(runs).each_with_object(+"") do |run, out|
        case run[:type].to_s
        when "string"
          out << Protocol::CALL_STRING << file_label!(run[:label], "string")
          next
        when "image", "dots"
          out << Protocol::CALL_DOTS << file_label!(run[:label], "image")
          next
        end

        text = normalize(run[:text].to_s)
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

    # Non-breaking spaces are an artefact of the browser's contenteditable
    # (it inserts U+00A0 to keep runs of spaces from collapsing), and the
    # sign has no glyph for one - it would arrive as the two UTF-8 bytes
    # C2 A0 and render as garbage. They always mean "a space" here, so
    # treat them as one.
    def self.normalize(text)
      text.tr("\u00A0", " ")
    end
    private_class_method :normalize

    def self.file_label!(label, kind)
      label = label.to_s
      unless label.length == 1
        raise ArgumentError, "#{kind} run needs a single-character file label, got #{label.inspect}"
      end

      label
    end
    private_class_method :file_label!
  end
end
