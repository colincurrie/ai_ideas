# Colour codes as documented in the XDF firmware user guide (section 3.21,
# "Supported Colour Codes"). The Ferrograph Aurora 63 is a 2-colour
# (red/green) matrix, so several named entries below produce identical
# output on the wire, and colours listed as "Alpha defined effect" variants
# of Dim Red/Dim Green/Brown/Orange collapse visually to plain
# red/green/yellow on this hardware, exactly as on genuine 2-line Alpha
# 4000-series signs. There is no RGB/hex colour support on this hardware -
# unlike RGB-pixel signs (e.g. Betabrite Prism), XDF only defines this fixed
# set of single-character colour codes after the 0x1C control code.
module AlphaSign
  module Colors
    NAMES = {
      "red" => "1", "green" => "2", "amber" => "3",
      "dim_red" => "4", "dim_green" => "5", "brown" => "6", "orange" => "7",
      "yellow" => "8",
      "rainbow1" => "9", "rainbow2" => "A", "mix" => "B", "auto" => "C",
      "stripe_red_green_red" => "D", "stripe_green_red_green" => "E",
      "stripe_red_yellow_red" => "F", "stripe_yellow_red_yellow" => "G",
      "stripe_green_yellow_green" => "H", "stripe_yellow_green_yellow" => "I",
      "rainbow1a" => "J", "rainbow1c" => "K", "rainbow2a" => "L",
      "rainbow2b" => "M", "rainbow2c" => "N", "rainbow1_staggered" => "O",
      "auto_offset1" => "P", "auto_offset2" => "Q",
      "rainbow1_sequenced" => "R", "rainbow2_sequenced" => "S",
      "rainbow1_sequenced_staggered" => "T", "rainbow2_sequenced_staggered" => "U",
      "mix_sequenced" => "V", "auto_fancy" => "W", "auto_plain" => "X",
      "small_rainbow1" => "a", "small_rainbow2" => "b", "small_rainbow3" => "c",
      "small_rainbow_staggered" => "d", "small_rainbow_sequenced" => "e",
      "small_rainbow_sequenced_staggered" => "f",
      "small_stripe_red_green" => "g", "small_stripe_green_red" => "h",
      "small_stripe_red_yellow" => "i", "small_stripe_yellow_red" => "j",
      "small_stripe_green_yellow" => "k", "small_stripe_yellow_green" => "l"
    }.freeze

    def self.lookup(name)
      code = NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown color #{name.inspect}; known colors: #{NAMES.keys.join(', ')}"
      end
      "\x1C#{code}"
    end
  end
end
