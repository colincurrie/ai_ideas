module AlphaSign
  module Speeds
    SPEED_1 = "\x15" # slowest
    SPEED_2 = "\x16"
    SPEED_3 = "\x17"
    SPEED_4 = "\x18"
    SPEED_5 = "\x19" # fastest

    def self.lookup(n)
      case n.to_i
      when 1 then SPEED_1
      when 2 then SPEED_2
      when 3 then SPEED_3
      when 4 then SPEED_4
      when 5 then SPEED_5
      else raise ArgumentError, "speed must be an integer from 1 (slowest) to 5 (fastest), got #{n.inspect}"
      end
    end
  end
end
