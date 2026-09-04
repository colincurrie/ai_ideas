require "time"

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

    # --- persistence ---
    #
    # The layout is the only record of what the sign is holding: XDF's
    # read-back didn't answer on real hardware (see docs/xdf-firmware-notes.md),
    # so a restart used to mean the service forgot everything while the sign
    # carried on displaying it. These two turn it into something that
    # survives.
    #
    # The pixel data goes in whole - a full-width picture is about 2KB of
    # digits, which is nothing to a file and is the only place it exists.
    def to_state
      {
        version: 1,
        saved_at: Time.now.utc.iso8601,
        configured_signature: @configured_signature,
        text: @text.transform_values(&:to_h),
        strings: @strings.transform_values(&:to_h),
        dots: @dots.transform_values(&:to_h)
      }
    end

    STATE_VERSION = 1

    # Rebuilds a layout from a saved state document.
    #
    # Strict, and raising ArgumentError with a specific message, because
    # this parses two quite different things: a file this service wrote, and
    # a file someone uploaded through the web app. The second is untrusted
    # and goes straight to the sign, so "which field is wrong" has to be
    # answerable. Callers choose what to do with the failure - the store
    # steps over it and boots empty, the endpoint turns it into a 400.
    def self.from_state(state)
      raise ArgumentError, "expected a JSON object, got #{state.class}" unless state.is_a?(Hash)

      version = state[:version]
      unless version.nil? || version == STATE_VERSION
        raise ArgumentError, "state version #{version.inspect} isn't one this version understands (expected #{STATE_VERSION})"
      end

      layout = new
      each_file(state, :text) do |label, file|
        runs = file[:runs] || []
        raise ArgumentError, "text file #{label.inspect}: runs must be a list, got #{runs.class}" unless runs.is_a?(Array)

        layout.put_text(label, runs: runs, position: file[:position],
                               mode: file[:mode], speed: file[:speed])
      end
      each_file(state, :strings) do |label, file|
        layout.put_string(label, text: file[:text].to_s)
      end
      each_file(state, :dots) do |label, file|
        width = positive_integer!(file[:width], "dots file #{label.inspect}: width")
        height = positive_integer!(file[:height], "dots file #{label.inspect}: height")
        pixels = file[:pixels].to_s
        if pixels.length != width * height
          raise ArgumentError, "dots file #{label.inspect}: expected #{width * height} pixels " \
                               "(#{width}x#{height}), got #{pixels.length}"
        end

        layout.put_dots(label, width: width, height: height,
                               pixels: pixels, monochrome: file[:monochrome])
      end
      # Restored as-is: the sign keeps its file layout in battery-backed
      # memory, so after an ordinary restart it still holds what this says.
      # When that's not true - the sign was reset, or something else wrote
      # to it - POST /resync re-sends everything.
      layout.configured_signature = state[:configured_signature]
      layout
    end

    # Walks one section of a state document, checking the shape as it goes.
    def self.each_file(state, kind)
      files = state[kind]
      return if files.nil?

      raise ArgumentError, "#{kind} must be an object of label => file, got #{files.class}" unless files.is_a?(Hash)

      files.each do |label, file|
        label = label.to_s
        # A file label is one character on the wire; anything else can't be
        # addressed, so it would fail later and more obscurely.
        raise ArgumentError, "#{kind} label #{label.inspect} must be a single character" unless label.length == 1
        raise ArgumentError, "#{kind} file #{label.inspect} must be an object, got #{file.class}" unless file.is_a?(Hash)

        yield label, file
      end
    end
    private_class_method :each_file

    def self.positive_integer!(value, what)
      integer = Integer(value)
      raise ArgumentError, "#{what} must be positive, got #{integer}" unless integer.positive?

      integer
    rescue TypeError, ArgumentError => e
      raise ArgumentError, e.message.start_with?(what) ? e.message : "#{what} must be a positive integer (#{value.inspect})"
    end
    private_class_method :positive_integer!

    attr_accessor :configured_signature

    # Forget what the sign was last configured for, so the next change
    # sends a fresh Memory Configuration and re-writes every file.
    def forget_configuration!
      @configured_signature = nil
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
