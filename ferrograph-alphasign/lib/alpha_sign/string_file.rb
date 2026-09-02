module AlphaSign
  # A STRING file: a chunk of text that a TEXT file can pull in by calling
  # it (AlphaSign::Runs' {type: "string"} run, control code 0x10 + label).
  #
  # The point of strings is cheap updates. String files are always double
  # buffered, so rewriting one swaps its contents in without blanking the
  # display or disturbing the message calling it - unlike a TEXT file
  # rewrite (which blanks by default) or a memory reconfiguration (which
  # erases every file). That makes them the right home for anything that
  # changes often while the surrounding message stays put.
  #
  # Two constraints from the XDF manual worth knowing:
  #   - A String file cannot call another String file.
  #   - Alpha's 125-byte limit doesn't apply on XDF (its dynamic double
  #     buffering lifts it to ~10K per memory page), but the file still has
  #     to fit the size reserved for it in the memory configuration.
  class StringFile
    attr_reader :label, :text

    def initialize(text, label: "1")
      @text = text.to_s
      @label = label
    end

    def contents
      "#{Protocol::WRITE_STRING}#{label}#{text}"
    end

    def to_packet(type: Protocol::TYPE_ALL, address: Protocol::BROADCAST_ADDRESS)
      Packet.new(contents, type: type, address: address)
    end
  end
end
