module AlphaSign
  module Colors
    RED       = "\x1C1"
    GREEN     = "\x1C2"
    AMBER     = "\x1C3"
    DIM_RED   = "\x1C4"
    DIM_GREEN = "\x1C5"
    BROWN     = "\x1C6"
    ORANGE    = "\x1C7"
    YELLOW    = "\x1C8"
    RAINBOW_1 = "\x1C9"
    RAINBOW_2 = "\x1CA"
    COLOR_MIX = "\x1CB"
    AUTOCOLOR = "\x1CC"

    NAMES = {
      "red" => RED, "green" => GREEN, "amber" => AMBER,
      "dim_red" => DIM_RED, "dim_green" => DIM_GREEN, "brown" => BROWN,
      "orange" => ORANGE, "yellow" => YELLOW, "rainbow1" => RAINBOW_1,
      "rainbow2" => RAINBOW_2, "mix" => COLOR_MIX, "auto" => AUTOCOLOR
    }.freeze

    HEX_RE = /\A#?([0-9A-Fa-f]{6})\z/

    # Full-color RGB, for signs with RGB/tri-color pixels. +hex+ is "RRGGBB",
    # an optional leading "#" is stripped.
    def self.rgb(hex)
      match = HEX_RE.match(hex)
      raise ArgumentError, "expected a 6-digit hex color like RRGGBB, got #{hex.inspect}" unless match

      "\x1CZ#{match[1].upcase}"
    end

    # Shadow/outline RGB color, layered behind the primary color set with
    # +rgb+.
    def self.shadow_rgb(hex)
      match = HEX_RE.match(hex)
      raise ArgumentError, "expected a 6-digit hex color like RRGGBB, got #{hex.inspect}" unless match

      "\x1CY#{match[1].upcase}"
    end

    # Accepts either a named color (see NAMES) or a bare/`#`-prefixed
    # RRGGBB hex string.
    def self.lookup(name)
      return rgb(name) if HEX_RE.match?(name)

      NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown color #{name.inspect}; known colors: #{NAMES.keys.join(', ')}, or a RRGGBB hex value"
      end
    end
  end
end
