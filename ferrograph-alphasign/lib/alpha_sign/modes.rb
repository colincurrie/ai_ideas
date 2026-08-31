module AlphaSign
  module Modes
    # Standard display modes
    ROTATE            = "a"
    HOLD              = "b"
    FLASH             = "c"
    ROLL_UP           = "e"
    ROLL_DOWN         = "f"
    ROLL_LEFT         = "g"
    ROLL_RIGHT        = "h"
    WIPE_UP           = "i"
    WIPE_DOWN         = "j"
    WIPE_LEFT         = "k"
    WIPE_RIGHT        = "l"
    SCROLL            = "m"
    AUTOMODE          = "o"
    ROLL_IN           = "p"
    ROLL_OUT          = "q"
    WIPE_IN           = "r"
    WIPE_OUT          = "s"
    COMPRESSED_ROTATE = "t" # only on certain sign models

    # Special modes (support varies by sign model/firmware)
    TWINKLE      = "n0"
    SPARKLE      = "n1"
    SNOW         = "n2"
    INTERLOCK    = "n3"
    SWITCH       = "n4"
    SPRAY        = "n6"
    STARBURST    = "n7"
    WELCOME      = "n8"
    SLOT_MACHINE = "n9"

    NAMES = {
      "rotate" => ROTATE, "hold" => HOLD, "flash" => FLASH,
      "roll_up" => ROLL_UP, "roll_down" => ROLL_DOWN,
      "roll_left" => ROLL_LEFT, "roll_right" => ROLL_RIGHT,
      "wipe_up" => WIPE_UP, "wipe_down" => WIPE_DOWN,
      "wipe_left" => WIPE_LEFT, "wipe_right" => WIPE_RIGHT,
      "scroll" => SCROLL, "automode" => AUTOMODE,
      "roll_in" => ROLL_IN, "roll_out" => ROLL_OUT,
      "wipe_in" => WIPE_IN, "wipe_out" => WIPE_OUT,
      "compressed_rotate" => COMPRESSED_ROTATE,
      "twinkle" => TWINKLE, "sparkle" => SPARKLE, "snow" => SNOW,
      "interlock" => INTERLOCK, "switch" => SWITCH, "spray" => SPRAY,
      "starburst" => STARBURST, "welcome" => WELCOME,
      "slot_machine" => SLOT_MACHINE
    }.freeze

    def self.lookup(name)
      NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown mode #{name.inspect}; known modes: #{NAMES.keys.join(', ')}"
      end
    end
  end
end
