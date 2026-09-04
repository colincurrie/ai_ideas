module AlphaSign
  # A response read back from the sign.
  #
  # XDF replies to a Read command "using the standard Alpha defined format
  # ... This has ASCII zeros ('0') for both the device identifier and
  # network address, and always incorporates a checksum" (XDF manual, §5),
  # in whichever low-level format the last message it received used - the
  # 1-byte format, in our case, since that's what Packet sends.
  #
  #   <NUL...> <SOH> <type> <address> <STX> contents <ETX> <checksum> <EOT>
  #
  # Parsing is deliberately forgiving: it keeps the raw bytes whatever
  # happens, and reports what it could and couldn't make sense of, rather
  # than raising. A reply that doesn't fit the shape above is far more
  # likely to mean this library has the request format wrong than that the
  # sign is broken - and in that case the raw bytes are the evidence, so
  # they must survive.
  class Response
    attr_reader :raw

    def initialize(raw)
      @raw = raw.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
    end

    def empty?
      raw.empty?
    end

    # Everything from <SOH> onwards, i.e. with the wake-up NULs trimmed.
    def frame
      start = raw.index(Protocol::SOH)
      start ? raw[start..] : nil
    end

    def type
      frame && frame[1]
    end

    def address
      frame && frame[2, 2]
    end

    # The command code plus its payload: what sits between <STX> and the
    # <ETX>/<EOT> that ends it.
    def contents
      body = frame
      return nil unless body

      stx = body.index(Protocol::STX)
      return nil unless stx

      finish = body.index(Protocol::ETX, stx) || body.index(Protocol::EOT, stx)
      finish ? body[(stx + 1)...finish] : body[(stx + 1)..]
    end

    # The 4 hex digits between <ETX> and <EOT>, when the reply carries one.
    def checksum
      body = frame
      etx = body&.index(Protocol::ETX)
      return nil unless etx

      body[(etx + 1), 4]
    end

    # The Alpha checksum is the 16-bit sum of every byte from <STX> to
    # <ETX> inclusive, as 4 ASCII hex digits.
    def computed_checksum
      body = frame
      etx = body&.index(Protocol::ETX)
      stx = body&.index(Protocol::STX)
      return nil unless etx && stx

      format("%04X", body[stx..etx].bytes.sum & 0xFFFF)
    end

    def checksum_ok?
      return nil if checksum.nil? # no checksum sent is not the same as a bad one

      checksum.upcase == computed_checksum
    end

    # Did we get a whole, well-formed frame back?
    def complete?
      !frame.nil? && frame.include?(Protocol::STX) && raw.include?(Protocol::EOT)
    end

    def to_hex
      raw.bytes.map { |b| format("%02X", b) }.join(" ")
    end

    # Control codes rendered as dot-escapes so a reply can be eyeballed in
    # a terminal or a JSON blob without the terminal acting on it.
    def to_printable
      raw.bytes.map { |b| b.between?(0x20, 0x7E) ? b.chr : format("<%02X>", b) }.join
    end

    def to_h
      {
        raw_hex: to_hex,
        printable: to_printable,
        complete: complete?,
        type: type,
        address: address,
        contents_printable: contents && contents.bytes.map { |b| b.between?(0x20, 0x7E) ? b.chr : format("<%02X>", b) }.join,
        contents_hex: contents&.bytes&.map { |b| format("%02X", b) }&.join(" "),
        checksum: checksum,
        computed_checksum: computed_checksum,
        checksum_ok: checksum_ok?
      }
    end
  end
end
