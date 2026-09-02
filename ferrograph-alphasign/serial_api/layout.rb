module SerialApi
  # Tracks what files the sign should hold (text, string and dots picture)
  # and their contents, and works out when a Memory Configuration actually
  # has to be sent.
  #
  # Why this exists: defining memory replaces the sign's ENTIRE file layout
  # and erases every file's contents. Sending one on each update - which an
  # earlier version of this service did for images - blanks the display and
  # throws away the very text files that were supposed to be showing the
  # image, so the sign just goes dark. Two rules avoid that:
  #
  #   1. Don't configure memory at all unless something needs it. XDF's
  #      power-on default already provides one full-page TEXT file per
  #      label (A onwards), which is all a text-only setup wants. Strings
  #      and dots pictures are what force a custom configuration.
  #   2. When a configuration IS sent, immediately re-send every file's
  #      contents, since they were just erased - and don't send another
  #      one until the layout genuinely changes.
  #
  # File sizes are rounded up to SIZE_GRANULARITY so that ordinary edits
  # (a message getting a few characters longer) stay inside the reservation
  # already made for them, rather than forcing a reconfiguration - and so a
  # blank - on every keystroke-sized change.
  class Layout
    SIZE_GRANULARITY = 256

    Text = Struct.new(:runs, :position, :mode, :speed, :keyword_init => true)
    Str = Struct.new(:text, keyword_init: true)
    Dots = Struct.new(:width, :height, :pixels, :monochrome, keyword_init: true)

    def initialize
      @text = {}
      @strings = {}
      @dots = {}
      @configured_signature = nil
    end

    attr_reader :text, :strings, :dots

    def put_text(label, runs:, position: nil, mode: nil, speed: nil)
      claim!(label, :text)
      @text[label] = Text.new(runs: runs, position: position, mode: mode, speed: speed)
    end

    def put_string(label, text:)
      claim!(label, :string)
      @strings[label] = Str.new(text: text)
    end

    def put_dots(label, width:, height:, pixels:, monochrome: false)
      claim!(label, :dots)
      @dots[label] = Dots.new(width: width, height: height, pixels: pixels, monochrome: monochrome)
    end

    def delete(kind, label)
      collection_for(kind).delete(label)
    end

    def empty?
      @text.empty? && @strings.empty? && @dots.empty?
    end

    # XDF's default layout covers text files just fine; only strings and
    # dots pictures need us to define memory ourselves.
    def custom_config_required?
      @strings.any? || @dots.any?
    end

    # The Memory Configuration this layout implies, or nil when the
    # default layout suffices.
    def memory_config
      return nil unless custom_config_required?

      config = AlphaSign::MemoryConfig.new
      @text.each { |label, file| config.text_file(label, size: reserved(text_bytes(file))) }
      @strings.each { |label, file| config.string_file(label, size: reserved(file.text.to_s.bytesize)) }
      @dots.each do |label, file|
        config.dots_file(label, height: file.height, width: file.width, monochrome: file.monochrome)
      end
      config
    end

    # True when the sign's current configuration no longer matches what
    # this layout needs - i.e. a reconfiguration (and a full content
    # re-send) is unavoidable.
    def needs_reconfiguration?
      memory_config&.contents != @configured_signature
    end

    def mark_configured!
      @configured_signature = memory_config&.contents
    end

    # Every file's content-write packet, for use straight after a
    # reconfiguration has wiped them.
    def content_packets(type:, address:)
      packets = []
      @text.each { |label, file| packets << text_packet(label, file, type: type, address: address) }
      @strings.each do |label, file|
        packets << AlphaSign::StringFile.new(file.text, label: label).to_packet(type: type, address: address)
      end
      @dots.each { |label, file| packets << dots_packet(label, file, type: type, address: address) }
      packets
    end

    def text_packet(label, file = @text[label], type:, address:)
      speed_prefix = file.speed ? AlphaSign::Speeds.lookup(file.speed) : ""
      AlphaSign::TextFile.new(
        speed_prefix + AlphaSign::Runs.encode(file.runs),
        label: label,
        position: AlphaSign::Positions.lookup(file.position || "fill"),
        mode: AlphaSign::Modes.lookup(file.mode || "automode")
      ).to_packet(type: type, address: address)
    end

    def string_packet(label, type:, address:)
      AlphaSign::StringFile.new(@strings[label].text, label: label).to_packet(type: type, address: address)
    end

    def dots_packet(label, file = @dots[label], type:, address:)
      dots_file(label, file).to_packet(type: type, address: address)
    end

    def dots_file(label, file = @dots[label])
      rows = file.pixels.chars.each_slice(file.width).map(&:join)
      AlphaSign::DotsFile.new(rows, label: label)
    end

    # Snapshot for GET /files - what's tracked, without the bulky pixel data.
    def to_h
      {
        text: @text.transform_values { |f| { runs: f.runs, position: f.position, mode: f.mode, speed: f.speed } },
        strings: @strings.transform_values { |f| { text: f.text } },
        dots: @dots.transform_values { |f| { width: f.width, height: f.height } }
      }
    end

    private

    # File labels are one namespace across all three file types: a memory
    # configuration lists each label once, with a type. Letting the same
    # label be both (say) a text file and a picture would emit two
    # contradictory entries for it, so refuse before that reaches the sign.
    def claim!(label, kind)
      { text: @text, string: @strings, dots: @dots }.each do |other_kind, files|
        next if other_kind == kind
        next unless files.key?(label)

        raise ArgumentError,
              "label #{label.inspect} is already in use by a #{other_kind} file - file labels are " \
              "shared across text, string and image files, so pick a different one (or delete that file first)"
      end
    end

    def collection_for(kind)
      case kind.to_s
      when "text" then @text
      when "string", "strings" then @strings
      when "dots", "image" then @dots
      else raise ArgumentError, "unknown file kind #{kind.inspect}"
      end
    end

    def text_bytes(file)
      speed_prefix = file.speed ? AlphaSign::Speeds.lookup(file.speed) : ""
      (speed_prefix + AlphaSign::Runs.encode(file.runs)).bytesize
    end

    def reserved(bytes)
      [(bytes / SIZE_GRANULARITY + 1) * SIZE_GRANULARITY, SIZE_GRANULARITY].max
    end
  end
end
