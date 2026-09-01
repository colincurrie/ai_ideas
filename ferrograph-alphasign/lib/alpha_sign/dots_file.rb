module AlphaSign
  # A Small Dots Picture file: a grid of pixels, each a single-character
  # color code (see AlphaSign::DotsColors). This is the only Dots Picture
  # format XDF supports (no large/AlphaVision, no RGB - see protocol.rb).
  #
  # Protocol provenance note: unlike the rest of this library, this wire
  # format isn't restated in the XDF manual (it just says "as defined in
  # the Alpha Protocol Manual"), and Alpha's own manual wasn't reachable to
  # verify directly. This is reconstructed from a third-party open-source
  # Alpha-protocol packet generator (darinfranklin/bbxml's alphasign.xsl),
  # cross-checked against the XDF manual's colour-depth/dimension notes and
  # its Run-Time-Table special values (which independently matched this
  # source's time-lookup table exactly - real->real->always->0xFF,
  # never->0xFE, all day->0xFD - giving good confidence). Still, verify
  # with a small test image before relying on this for anything important.
  class DotsFile
    MAX_HEIGHT = 32  # protocol limit
    MAX_WIDTH = 255  # protocol limit
    # Literal CR (0x0D) marking the end of each row, sent via the 3-byte
    # escape form so XDF reads it as a literal data byte rather than the
    # New Line control code (which 0x0D would otherwise trigger - see
    # Appendix A in docs/xdf-firmware-notes.md).
    ROW_TERMINATOR = "_0D"

    attr_reader :label, :rows

    # +rows+ is an array of rows, each either a String of digit characters
    # or an array of codes/names (see AlphaSign::DotsColors.lookup).
    def initialize(rows, label: "P")
      @rows = rows.map { |row| normalize_row(row) }
      @label = label
      validate_dimensions!
    end

    def height
      rows.size
    end

    def width
      rows.first&.length || 0
    end

    def contents
      header = "#{Protocol::WRITE_SMALL_DOTS}#{label}#{size_field(height)}#{size_field(width)}"
      header + rows.map { |row| row.join + ROW_TERMINATOR }.join
    end

    def to_packet(type: Protocol::TYPE_ALL, address: Protocol::BROADCAST_ADDRESS)
      Packet.new(contents, type: type, address: address)
    end

    # Fraction (0.0-1.0) of pixels that are lit at all (any non-off color).
    def lit_fraction
      total = height * width
      return 0.0 if total.zero?

      lit = rows.sum { |row| row.count { |px| px != DotsColors::OFF } }
      lit.to_f / total
    end

    # LED chip load, as a fraction of the theoretical maximum (every pixel
    # yellow). The XDF manual warns this hardware isn't built to sustain
    # more than 50% of LED chips lit at once, and explicitly calls out that
    # "each yellow dot counts as two chips" (red+green together) - so a
    # simple lit-pixel-count isn't the right measure; this is.
    def lit_chip_fraction
      total = height * width
      return 0.0 if total.zero?

      chips = rows.sum do |row|
        row.sum { |px| px == DotsColors::YELLOW ? 2 : (px == DotsColors::OFF ? 0 : 1) }
      end
      chips.to_f / (total * 2)
    end

    private

    def normalize_row(row)
      pixels = row.is_a?(String) ? row.chars : row
      pixels.map { |px| DotsColors.lookup(px) }
    end

    def size_field(value)
      format("%02X", value)
    end

    def validate_dimensions!
      raise ArgumentError, "dots picture must have at least one row" if rows.empty?
      raise ArgumentError, "dots picture rows must all be the same width" if rows.map(&:length).uniq.size > 1
      raise ArgumentError, "dots picture width must be at least 1 pixel" if width < 1
      raise ArgumentError, "dots picture height #{height} exceeds the protocol maximum of #{MAX_HEIGHT}" if height > MAX_HEIGHT
      raise ArgumentError, "dots picture width #{width} exceeds the protocol maximum of #{MAX_WIDTH}" if width > MAX_WIDTH
    end
  end
end
