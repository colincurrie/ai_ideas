module AlphaSign
  # A complete Alpha protocol transmission packet:
  #
  #   <NUL x5> <SOH> <type code> <address> <STX> contents <EOT>
  #
  # +contents+ is everything after <STX>: the command code byte followed by
  # that command's payload (e.g. WRITE_TEXT + label + ESC + position + mode
  # + message text).
  class Packet
    def initialize(contents, type: Protocol::TYPE_ALL, address: Protocol::BROADCAST_ADDRESS)
      raise ArgumentError, "type code must be exactly 1 character" unless type.length == 1
      raise ArgumentError, "address must be exactly 2 characters" unless address.length == 2

      @bytes = (Protocol::WAKEUP + Protocol::SOH + type + address +
                Protocol::STX + contents + Protocol::EOT).dup.force_encoding(Encoding::ASCII_8BIT)
    end

    def to_s
      @bytes
    end

    def bytes
      @bytes.bytes
    end

    def to_hex
      bytes.map { |b| format("%02X", b) }.join(" ")
    end
  end
end
