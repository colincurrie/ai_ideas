# Per-pixel color codes for a Small Dots Picture file (XDF manual, section
# 3.13). Unlike text color codes, these are bare digit characters with no
# 0x1C control-code prefix - each pixel is exactly one ASCII character.
#
# The manual lists codes "0" through "8", but on this 2-colour (red/green)
# hardware everything above "3" collapses to the same 4 visible outcomes
# (matching the same red/dim-red, yellow/brown/orange/yellow collapse seen
# in AlphaSign::Colors), so only the 4 practically distinct codes are
# exposed here.
module AlphaSign
  module DotsColors
    OFF    = "0"
    RED    = "1"
    GREEN  = "2"
    YELLOW = "3"

    NAMES = { "off" => OFF, "red" => RED, "green" => GREEN, "yellow" => YELLOW }.freeze
    CODES = NAMES.values.freeze

    # Accepts either a bare code ("0".."3") or a name ("off"/"red"/etc).
    def self.lookup(value)
      return value if CODES.include?(value)

      NAMES.fetch(value.is_a?(String) ? value.downcase : value) do
        raise ArgumentError, "unknown dots color #{value.inspect}; known colors: #{NAMES.keys.join(', ')}"
      end
    end
  end
end
