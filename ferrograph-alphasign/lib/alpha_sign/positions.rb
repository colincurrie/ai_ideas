# Display positions (XDF user guide, section 3.17). Note that the Alpha 3.0
# LEFT/RIGHT positions are explicitly *not* supported by XDF ("These are not
# supported by XDF, and never will be, as they are only relevant for large
# area displays"), so only these four are offered.
module AlphaSign
  module Positions
    MIDDLE = "\x20"
    TOP    = "\x22"
    BOTTOM = "\x26"
    FILL   = "\x30"

    NAMES = {
      "middle" => MIDDLE, "top" => TOP, "bottom" => BOTTOM, "fill" => FILL
    }.freeze

    def self.lookup(name)
      NAMES.fetch(name.downcase) do
        raise ArgumentError, "unknown position #{name.inspect}; known positions: #{NAMES.keys.join(', ')}"
      end
    end
  end
end
