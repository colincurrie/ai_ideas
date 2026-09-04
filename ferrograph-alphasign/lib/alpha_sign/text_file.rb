module AlphaSign
  # Builds the payload for a WRITE_TEXT command:
  #
  #   WRITE_TEXT + label + ESC + position + mode + message
  #
  # An empty message clears/blanks that TEXT file's label on the sign.
  class TextFile
    attr_accessor :text, :label, :position, :mode

    def initialize(text, label: "A", position: Positions::MIDDLE, mode: Modes::HOLD, priority: false)
      @text = text
      @label = priority ? "0" : label
      @position = position
      @mode = mode
    end

    def contents
      return "#{Protocol::WRITE_TEXT}#{label}" if text.nil? || text.empty?

      "#{Protocol::WRITE_TEXT}#{label}#{Protocol::ESC}#{position}#{mode}#{text}"
    end

    def to_packet(type: Protocol::TYPE_ALL, address: Protocol::BROADCAST_ADDRESS)
      Packet.new(contents, type: type, address: address)
    end
  end
end
