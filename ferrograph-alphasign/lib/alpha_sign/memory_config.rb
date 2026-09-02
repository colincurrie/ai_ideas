module AlphaSign
  # Builds a Define Memory Configuration command (Special Function "$",
  # 0x24H). This is how a label gets defined as a Dots Picture file in the
  # first place - AlphaSign::DotsFile can only *write* to an already
  # existing Dots file, it can't create one.
  #
  # IMPORTANT: sending this REPLACES the sign's entire file layout, not
  # just the entries listed here - any label not included stops existing.
  # See docs/xdf-firmware-notes.md ("Flexible Paged Memory Filesystem").
  #
  # Same protocol-provenance caveat as AlphaSign::DotsFile applies here -
  # see that file's comment.
  class MemoryConfig
    ALWAYS = "FF" # Run Time "Always" - the file is permanently enabled
    NEVER  = "FE" # Run Time "Never"

    def initialize
      @entries = []
    end

    # +size+ is the number of bytes to reserve for this text file's content.
    def text_file(label, size:, locked: false, start: ALWAYS, stop: ALWAYS)
      @entries << "#{label}A#{lock_flag(locked)}#{format('%04X', size)}#{start}#{stop}"
      self
    end

    # +size+ is the number of bytes to reserve for this string file's
    # content. The trailing "0000" and the always-Locked flag aren't
    # choices - that's the documented entry shape for strings (XDF manual,
    # Appendix E: "<File Label>BL<Size in hex>0000", with the worked
    # example ABL04000000BBL04000000CBL04000000 for three 1K strings).
    def string_file(label, size:)
      @entries << "#{label}BL#{format('%04X', size)}0000"
      self
    end

    # +height+/+width+ must match what will later be written via DotsFile
    # for this label.
    def dots_file(label, height:, width:, locked: false, monochrome: false)
      depth_code = monochrome ? "1000" : "2000" # XDF's other depth ("4000"/8-colour) maps to the
      # same 3-colour output as "2000" on this 2-colour hardware, so it isn't offered here.
      @entries << "#{label}D#{lock_flag(locked)}#{format('%02X', height)}#{format('%02X', width)}#{depth_code}"
      self
    end

    def contents
      "#{Protocol::WRITE_SPECIAL}#{Protocol::MEMORY_CONFIG}#{@entries.join}"
    end

    def to_packet(type: Protocol::TYPE_ALL, address: Protocol::BROADCAST_ADDRESS)
      Packet.new(contents, type: type, address: address)
    end

    private

    def lock_flag(locked)
      locked ? "L" : "U"
    end
  end
end
