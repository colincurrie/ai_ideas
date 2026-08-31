module AlphaSign
  module Positions
    MIDDLE = "\x20"
    TOP    = "\x22"
    BOTTOM = "\x26"
    FILL   = "\x30"
    LEFT   = "\x31" # Alpha 3.0 protocol signs only
    RIGHT  = "\x32" # Alpha 3.0 protocol signs only

    NAMES = {
      "middle" => MIDDLE, "top" => TOP, "bottom" => BOTTOM,
      "fill" => FILL, "left" => LEFT, "right" => RIGHT
    }.freeze

    def self.lookup(name)
      NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown position #{name.inspect}; known positions: #{NAMES.keys.join(', ')}"
      end
    end
  end
end
