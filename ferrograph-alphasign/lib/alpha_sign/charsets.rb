# Character set (font) codes, as documented in the XDF firmware user guide,
# section 3.14 ("Supported Character Sets"). Selected via control code 0x1A
# followed by one of these single-character codes.
#
# The manual's table also lists codes "7", "9" and "A" as Alpha-compatible
# aliases that render identically to "4", "6" and "8" respectively on this
# hardware (XDF doesn't have distinct 10-high fonts, so it substitutes the
# nearest equivalent) - they're omitted from NAMES to keep the exposed list
# to the 7 practically distinct fonts, but can still be reached via the
# `raw` command/API if ever needed.
module AlphaSign
  module CharSets
    FIVE_HIGH               = "1"
    HYBRID                  = "2" # 7 high, with 5 high lowercase letters
    SEVEN_HIGH               = "3" # XDF default
    SEVEN_HIGH_FANCY_NARROW = "4" # single column spacing - best for lowercase
    SEVEN_HIGH_FANCY        = "5" # standard 2 column spacing - best for capitals/numbers
    LARGE_STANDARD           = "6"
    LARGE_FANCY               = "8"

    NAMES = {
      "five_high" => FIVE_HIGH,
      "hybrid" => HYBRID,
      "seven_high" => SEVEN_HIGH,
      "seven_high_fancy_narrow" => SEVEN_HIGH_FANCY_NARROW,
      "seven_high_fancy" => SEVEN_HIGH_FANCY,
      "large_standard" => LARGE_STANDARD,
      "large_fancy" => LARGE_FANCY
    }.freeze

    def self.lookup(name)
      code = NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown font #{name.inspect}; known fonts: #{NAMES.keys.join(', ')}"
      end
      "\x1A#{code}"
    end
  end
end
