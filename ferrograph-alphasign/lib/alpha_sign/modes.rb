# Display modes, as documented in the XDF firmware user guide, Appendix C
# ("List of Basic Effect Modes Supported by XDF") and Appendix D ("List of
# Extended Effect Modes Supported by XDF"). Byte codes for the basic effects
# match the generic Alpha protocol codes, but several are repurposed by XDF
# for different (usually improved) effects than genuine Alpha hardware, and
# XDF adds many extended effects beyond the standard Alpha set - all of
# these are reachable via the "n" (Invoke Extended Effect) basic code
# followed by an extended effect code.
module AlphaSign
  module Modes
    # Basic effect modes (Appendix C)
    ROTATE            = "a" # slow rotate (travel) left, continuous updates
    HOLD              = "b" # fixed display
    FLASH             = "c" # fixed display, continually flashing
    AUTOMODE_ALT      = "d" # AutoMode (alternate code, same as "o")
    ROLL_UP           = "e" # fast vertical scroll up
    ROLL_DOWN         = "f" # fast vertical scroll down
    ROLL_LEFT         = "g" # fast scroll left
    ROLL_RIGHT        = "h" # fast scroll right
    WIPE_UP           = "i" # vertical wipe up
    WIPE_DOWN         = "j" # vertical wipe down
    WIPE_LEFT         = "k" # horizontal wipe left
    WIPE_RIGHT        = "l" # horizontal wipe right
    SCROLL            = "m" # progressive full screen scroll up (position code ignored)
    AUTOMODE          = "o" # AutoMode (every effect under the sun)
    ROLL_IN           = "p" # implode scroll (two halves scroll inward)
    ROLL_OUT          = "q" # explode scroll (two halves scroll outward)
    WIPE_IN           = "r" # implode wipe (two halves wipe inward)
    WIPE_OUT          = "s" # explode wipe (two halves wipe outward)
    COMPRESSED_ROTATE = "t" # slow horizontal scroll left, half speed
    VERTICAL_EXPLODE  = "u" # vertical explode scroll (top/bottom outward)
    SLOW_SCROLL_RIGHT = "v" # slow horizontal scroll right, half speed
    SLOW_SCROLL_UP    = "w" # slow vertical scroll up, half speed
    SLOW_SCROLL_DOWN  = "x" # slow vertical scroll down, half speed

    # Extended effect modes (Appendix D) - reached via "n" + code below
    TWINKLE                     = "n0"
    DISSOLVE                    = "n1" # 16-step dissolve; called "Sparkle" on genuine Alpha signs
    SNOW                        = "n2"
    INTERLOCK_WIPE_1            = "n3"
    SWITCH_FAST                 = "n4"
    SLIDE                       = "n5"
    DISSOLVE_WIPE               = "n6" # called "Spray" on genuine Alpha signs
    CURSOR_WIPE                 = "n7" # called "Starburst" on genuine Alpha signs
    INTERLOCK_WIPE_2            = "n8" # called "Welcome" on genuine Alpha signs
    INTERLOCK_SCROLL_1          = "n9" # called "Slot Machine" on genuine Alpha signs
    INTERLOCK_SCROLL_2          = "nA" # called "News Flash" on Betabrite signs
    SLOW_DROP_DOWN              = "nB" # called "Trumpet" on Betabrite signs
    COLOUR_CYCLE                = "nC"
    FADE_SLOW                   = "nD" # XDF only
    FADE_FAST                   = "nE" # XDF only
    FAST_DROP_DOWN              = "nF" # XDF only
    COLOUR_SPLIT_SIMULTANEOUS_1 = "nG" # XDF only
    COLOUR_SPLIT_SIMULTANEOUS_2 = "nH" # XDF only
    COLOUR_SPLIT_BIDIRECTIONAL_1 = "nI" # XDF only
    COLOUR_SPLIT_BIDIRECTIONAL_2 = "nJ" # XDF only
    COLOUR_SPLIT_UNIDIRECTIONAL_1 = "nK" # XDF only
    COLOUR_SPLIT_UNIDIRECTIONAL_2 = "nL" # XDF only
    COVER_RIGHT_TO_LEFT         = "nM" # XDF only
    COVER_LEFT_TO_RIGHT         = "nN" # XDF only
    REVEAL_RIGHT_TO_LEFT        = "nO" # XDF only
    REVEAL_LEFT_TO_RIGHT        = "nP" # XDF only
    SWITCH_SLOW                 = "nS" # called "Thank You" on genuine Alpha signs
    VERTICAL_IMPLODE_SCROLL     = "nU" # called "No Smoking" on genuine Alpha signs
    VERTICAL_EXPLODE_SCROLL     = "nV" # called "Don't Drink & Drive" on genuine Alpha signs
    VERTICAL_IMPLODE_WIPE       = "nW" # called "Running Animal" on genuine Alpha signs
    VERTICAL_EXPLODE_WIPE       = "nX" # called "Fireworks" on genuine Alpha signs
    COLOUR_SPLIT_SIMULTANEOUS_1B = "nY" # called "Turbo Car" on genuine Alpha signs
    COLOUR_SPLIT_BIDIRECTIONAL_1B = "nZ" # called "Cherry Bomb" on genuine Alpha signs

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
      "vertical_explode" => VERTICAL_EXPLODE,
      "slow_scroll_right" => SLOW_SCROLL_RIGHT,
      "slow_scroll_up" => SLOW_SCROLL_UP,
      "slow_scroll_down" => SLOW_SCROLL_DOWN,
      "twinkle" => TWINKLE, "dissolve" => DISSOLVE, "snow" => SNOW,
      "interlock_wipe_1" => INTERLOCK_WIPE_1, "switch_fast" => SWITCH_FAST,
      "slide" => SLIDE, "dissolve_wipe" => DISSOLVE_WIPE,
      "cursor_wipe" => CURSOR_WIPE, "interlock_wipe_2" => INTERLOCK_WIPE_2,
      "interlock_scroll_1" => INTERLOCK_SCROLL_1,
      "interlock_scroll_2" => INTERLOCK_SCROLL_2,
      "slow_drop_down" => SLOW_DROP_DOWN, "colour_cycle" => COLOUR_CYCLE,
      "fade_slow" => FADE_SLOW, "fade_fast" => FADE_FAST,
      "fast_drop_down" => FAST_DROP_DOWN,
      "colour_split_simultaneous_1" => COLOUR_SPLIT_SIMULTANEOUS_1,
      "colour_split_simultaneous_2" => COLOUR_SPLIT_SIMULTANEOUS_2,
      "colour_split_bidirectional_1" => COLOUR_SPLIT_BIDIRECTIONAL_1,
      "colour_split_bidirectional_2" => COLOUR_SPLIT_BIDIRECTIONAL_2,
      "colour_split_unidirectional_1" => COLOUR_SPLIT_UNIDIRECTIONAL_1,
      "colour_split_unidirectional_2" => COLOUR_SPLIT_UNIDIRECTIONAL_2,
      "cover_right_to_left" => COVER_RIGHT_TO_LEFT,
      "cover_left_to_right" => COVER_LEFT_TO_RIGHT,
      "reveal_right_to_left" => REVEAL_RIGHT_TO_LEFT,
      "reveal_left_to_right" => REVEAL_LEFT_TO_RIGHT,
      "switch_slow" => SWITCH_SLOW,
      "vertical_implode_scroll" => VERTICAL_IMPLODE_SCROLL,
      "vertical_explode_scroll" => VERTICAL_EXPLODE_SCROLL,
      "vertical_implode_wipe" => VERTICAL_IMPLODE_WIPE,
      "vertical_explode_wipe" => VERTICAL_EXPLODE_WIPE
    }.freeze

    def self.lookup(name)
      NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown mode #{name.inspect}; known modes: #{NAMES.keys.join(', ')}"
      end
    end
  end
end
