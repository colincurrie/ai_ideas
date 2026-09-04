# frozen_string_literal: true

module FakeSign
  # Every number that governs how fast something moves, in one place.
  #
  # Two kinds live here, and the difference matters:
  #
  #   MEASURED FROM THE MANUAL - stated outright in the XDF manual, so
  #   these are as good as the documentation gets.
  #
  #   ESTIMATED - the manual is silent, and these are guesses that make the
  #   preview look plausible. They are NOT observations of the hardware.
  #   Anything reading the preview to answer "how long will this take?" is
  #   reading a guess. tools/fake_sign/CALIBRATION.md says how to replace
  #   them with measurements from a filmed sign.
  module Timings
    # --- From the manual (section 26, "Effect Pause Control") ---
    #
    # The pause between fixed-format frames, by speed control code.
    SPEED_PAUSES = {
      "\x15" => 17.0,  # Speed 1 - longest
      "\x16" => 9.0,   # Speed 2
      "\x17" => 4.5,   # Speed 3 - the sign's default
      "\x18" => 2.2,   # Speed 4
      "\x19" => 1.0    # Speed 5 - shortest
    }.freeze
    DEFAULT_PAUSE = 4.5 # section 26 marks Speed 3 as the default

    # --- Estimated: the manual gives no figure ---

    # How fast a Rotate (travelling) message crosses the display. The
    # manual describes 61H as "slow rotate (travel) to the left, continuous
    # updates" and never says how slow. ESTIMATE.
    ROTATE_PIXELS_PER_SECOND = 30.0

    # How long a transition takes to complete - the roll, wipe, implode and
    # explode effects. The manual names them and describes their shapes but
    # gives no duration. ESTIMATE.
    TRANSITION_SECONDS = 0.7
    # The "slow ... (half speed version)" effects (74H, 76H, 77H, 78H) are
    # explicitly half speed, so this one is a relationship the manual does
    # state, applied to an estimated base.
    SLOW_TRANSITION_MULTIPLIER = 2.0

    # Flash Mode (63H): "fixed display, continually flashing". Rate not
    # given. ESTIMATE.
    FLASH_PERIOD_SECONDS = 1.0

    # No Hold (09H) is "Minimal (configurable)" per the manual, and depends
    # on the XDF Set Animation Execution Delay config item and the control
    # board fitted. ESTIMATE.
    NO_HOLD_SECONDS = 0.15

    # Which numbers above are guesses, for the preview to say so honestly.
    ESTIMATED = %w[
      ROTATE_PIXELS_PER_SECOND TRANSITION_SECONDS FLASH_PERIOD_SECONDS NO_HOLD_SECONDS
    ].freeze

    def self.pause_for(speed_code)
      return NO_HOLD_SECONDS if speed_code == "\x09"

      SPEED_PAUSES.fetch(speed_code, DEFAULT_PAUSE)
    end

    def self.to_h
      {
        rotate_pixels_per_second: ROTATE_PIXELS_PER_SECOND,
        transition_seconds: TRANSITION_SECONDS,
        slow_transition_multiplier: SLOW_TRANSITION_MULTIPLIER,
        flash_period_seconds: FLASH_PERIOD_SECONDS,
        no_hold_seconds: NO_HOLD_SECONDS,
        default_pause: DEFAULT_PAUSE,
        estimated: ESTIMATED
      }
    end
  end

  # Appendix C maps effect codes to the motion they produce; Appendix D
  # does the same for the extended effects invoked by "n".
  module Effects
    BASIC = {
      "a" => { motion: :rotate,        description: "slow rotate (travel) left, continuous" },
      "b" => { motion: :hold,          description: "hold - fixed display" },
      "c" => { motion: :flash,         description: "flash - fixed display, continually flashing" },
      "d" => { motion: :auto,          description: "AutoMode" },
      "e" => { motion: :roll_up,       description: "fast vertical scroll up" },
      "f" => { motion: :roll_down,     description: "fast vertical scroll down" },
      "g" => { motion: :roll_left,     description: "fast scroll left" },
      "h" => { motion: :roll_right,    description: "fast scroll right" },
      "i" => { motion: :wipe_up,       description: "vertical wipe up" },
      "j" => { motion: :wipe_down,     description: "vertical wipe down" },
      "k" => { motion: :wipe_left,     description: "horizontal wipe left" },
      "l" => { motion: :wipe_right,    description: "horizontal wipe right" },
      "m" => { motion: :scroll,        description: "progressive full screen scroll up (position ignored)" },
      "n" => { motion: :extended,      description: "invoke extended effect" },
      "o" => { motion: :auto,          description: "AutoMode" },
      "p" => { motion: :implode_scroll, description: "implode scroll - two halves scroll inward" },
      "q" => { motion: :explode_scroll, description: "explode scroll - two halves scroll outward" },
      "r" => { motion: :implode_wipe,  description: "implode wipe - two halves wipe inward" },
      "s" => { motion: :explode_wipe,  description: "explode wipe - two halves wipe outward" },
      "t" => { motion: :roll_left,     description: "slow horizontal scroll left (half speed)", slow: true },
      "u" => { motion: :explode_vertical, description: "vertical explode scroll" },
      "v" => { motion: :roll_right,    description: "slow horizontal scroll right (half speed)", slow: true },
      "w" => { motion: :roll_up,       description: "slow vertical scroll up (half speed)", slow: true },
      "x" => { motion: :roll_down,     description: "slow vertical scroll down (half speed)", slow: true }
    }.freeze

    # Appendix D. These are decorative rather than geometric: the preview
    # approximates their character (a sparkle, a dissolve) rather than
    # reproducing the sign's actual pattern, which the manual doesn't give.
    EXTENDED = {
      "0" => { motion: :twinkle,  description: "twinkle - continuous shifting dot crawl" },
      "1" => { motion: :dissolve, description: "dissolve - old message dissolves into new" },
      "2" => { motion: :snow,     description: "snow - new message snows onto the display" },
      "3" => { motion: :interlock_wipe, description: "interlock wipe 1" },
      "4" => { motion: :switch,   description: "fast switch - alternate characters roll up and down" },
      "5" => { motion: :slide,    description: "slide - characters slide in from the right" },
      "6" => { motion: :dissolve_wipe, description: "dissolve-wipe, left to right" },
      "7" => { motion: :cursor_wipe, description: "cursor wipe - yellow cursor wipes left to right" },
      "8" => { motion: :interlock_wipe, description: "interlock wipe 2" },
      "9" => { motion: :interlock_scroll, description: "interlock scroll 1" },
      "A" => { motion: :interlock_scroll, description: "interlock scroll 2" }
    }.freeze

    # Approximated rather than reproduced - said out loud in the preview.
    APPROXIMATED = %i[twinkle dissolve snow switch slide dissolve_wipe cursor_wipe
                      interlock_wipe interlock_scroll auto].freeze

    def self.lookup(code, extended_code = nil)
      basic = BASIC[code] || { motion: :hold, description: "unknown effect #{code.inspect}" }
      return basic unless basic[:motion] == :extended

      extended = EXTENDED[extended_code] ||
                 { motion: :hold, description: "unknown extended effect #{extended_code.inspect}" }
      extended.merge(extended_code: extended_code)
    end
  end
end
