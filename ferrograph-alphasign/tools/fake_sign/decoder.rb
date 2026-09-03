# frozen_string_literal: true

# A strict decoder for the Alpha/XDF wire protocol: bytes in, structured
# commands out, complaining about anything the XDF manual doesn't allow.
#
# WHY THIS IS WRITTEN THE WAY IT IS
#
# This is deliberately NOT built on lib/alpha_sign. It is written from the
# XDF firmware manual, and it rejects rather than tolerates. A decoder
# derived from our own encoder would be a mirror: it would accept whatever
# we happen to emit and confirm every assumption we already hold. That is
# exactly how this project shipped a Dots row terminator of "_0D" - the
# 3-byte format's escape for 0x0D, sent inside a 1-byte frame where "_" is
# just an underscore - and never noticed until a real sign displayed a
# picture as its top row and nothing else. Every test we had encoded the
# same mistake as the code.
#
# So the rule for this file: cite the manual, not lib/. If a check here
# disagrees with our encoder, that disagreement is the finding.
#
# Findings come in two severities, and the distinction matters:
#   :error   - the sign would reject or misread this. A real bug.
#   :warning - the sign tolerates it (the manual says so explicitly), but
#              it is probably not what the sender meant.
module FakeSign
  Finding = Struct.new(:severity, :message, :offset, keyword_init: true) do
    def to_s
      "#{severity.to_s.upcase} at byte #{offset}: #{message}"
    end
  end

  # One decoded command, plus whatever was wrong with it.
  Command = Struct.new(:kind, :type_code, :address, :fields, :raw, :findings, keyword_init: true) do
    def ok?
      findings.none? { |f| f.severity == :error }
    end
  end

  class Decoder
    # Manual section 1: "The selected format is detected by the nature of
    # the SOH code, either 01H for the 1 byte format, 5DH, 21H for the 2
    # byte format or 5FH, 30H, 31H for the 3 byte format."
    SOH_1BYTE = 0x01
    SOH_2BYTE_LEAD = 0x5D
    SOH_3BYTE_LEAD = 0x5F
    STX = 0x02
    ETX = 0x03
    EOT = 0x04
    ESC = 0x1B

    # Appendix A: control codes, and how many parameter bytes each takes.
    # A code that isn't here has no business inside message text.
    CONTROL_PARAMS = {
      0x07 => 1, # Character Flash Attribute (state)
      0x08 => 1, # Display extended character or Temperature
      0x09 => 0, # No Hold
      0x0B => 1, # Display date in specified format
      0x0C => 0, # New Page
      0x0D => 0, # New Line
      0x0E => 1, # XDF Time Display code
      0x0F => 1, # Alpha 2.0 speed control
      0x10 => 1, # Call String File (label)
      0x11 => 0, # Disable wide characters
      0x12 => 0, # Enable wide characters
      0x13 => 0, # Display time of day
      0x14 => 1, # Call Dots Picture File (label)
      0x15 => 0, # Speed 1
      0x16 => 0, # Speed 2
      0x17 => 0, # Speed 3
      0x18 => 0, # Speed 4
      0x19 => 0, # Speed 5
      0x1A => 1, # Select character set
      0x1C => 1, # Set colour
      0x1D => 2, # Set attribute state
      0x1E => 1  # Character spacing/justification mode
    }.freeze

    # Section 21. Codes outside this set are not colours.
    COLOUR_CODES = ("1".."8").to_a + ("9".."9").to_a + ("A".."W").to_a
    # Section 14. Note the manual's own note: "any unrecognised code always
    # selects standard 7 high characters with XDF" - so a bad charset code
    # is tolerated by the sign, hence a warning rather than an error.
    CHARSET_CODES = %w[1 2 3 4 5 6 7 8 9 A].freeze

    # Section 17.
    POSITION_CODES = { 0x20 => :middle, 0x22 => :top, 0x26 => :bottom, 0x30 => :fill }.freeze
    # Appendix C: 61H-78H.
    EFFECT_CODES = (0x61..0x78).to_a.freeze
    EXTENDED_EFFECT_TRIGGER = 0x6E # "n"
    # Appendix D.
    EXTENDED_EFFECT_CODES = (("0".."9").to_a + ("A".."Z").to_a).freeze

    def initialize
      @buffer = +""
      @buffer.force_encoding(Encoding::ASCII_8BIT)
    end

    # Feed bytes as they arrive off the wire. Returns the commands that
    # completed with this chunk; anything partial stays buffered.
    def feed(bytes)
      @buffer << bytes.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
      commands = []
      while (command = take_frame)
        commands << command
      end
      commands
    end

    private

    def take_frame
      start = find_frame_start
      return nil unless start

      eot = @buffer.index(EOT.chr, start)
      return nil unless eot # frame still arriving

      raw = @buffer[start..eot]
      @buffer = @buffer[(eot + 1)..] || +"".b
      decode_frame(raw)
    end

    # Anything before the SOH is wake-up padding (or noise); skip it.
    def find_frame_start
      @buffer.bytes.each_index do |i|
        byte = @buffer.getbyte(i)
        return i if [SOH_1BYTE, SOH_2BYTE_LEAD, SOH_3BYTE_LEAD].include?(byte)
      end
      nil
    end

    def decode_frame(raw)
      findings = []
      soh = raw.getbyte(0)

      unless soh == SOH_1BYTE
        # Not a failure of the sender - the manual allows all three formats -
        # but this emulator only decodes the one this project sends, and
        # saying so is better than guessing at the bytes.
        return Command.new(kind: :unsupported_format, type_code: nil, address: nil,
                           fields: { soh: format("%02X", soh) }, raw: raw,
                           findings: [Finding.new(severity: :warning, offset: 0,
                                                  message: "frame uses the #{soh == SOH_2BYTE_LEAD ? '2' : '3'}-byte " \
                                                           "control format; this emulator only decodes the 1-byte format (SOH 01H)")])
      end

      type_code = raw[1]
      address = raw[2, 2]
      findings << Finding.new(severity: :error, offset: 1, message: "frame ended before the type code and address") if raw.length < 5

      stx = raw.index(STX.chr)
      unless stx
        findings << Finding.new(severity: :error, offset: 0, message: "no STX in frame - nothing to execute")
        return Command.new(kind: :malformed, type_code: type_code, address: address,
                           fields: {}, raw: raw, findings: findings)
      end

      etx = raw.index(ETX.chr, stx)
      body_end = etx || raw.index(EOT.chr, stx)
      contents = raw[(stx + 1)...body_end]

      if etx
        checksum = raw[(etx + 1), 4]
        expected = format("%04X", raw[stx..etx].bytes.sum & 0xFFFF)
        if checksum.nil? || checksum.length < 4
          findings << Finding.new(severity: :error, offset: etx + 1, message: "ETX present but the 4-digit checksum is truncated")
        elsif checksum.upcase != expected
          findings << Finding.new(severity: :error, offset: etx + 1,
                                  message: "checksum #{checksum} doesn't match the computed #{expected}")
        end
      end

      decode_contents(contents, type_code, address, raw, findings)
    end

    def decode_contents(contents, type_code, address, raw, findings)
      if contents.nil? || contents.empty?
        findings << Finding.new(severity: :error, offset: 0, message: "empty command body")
        return Command.new(kind: :malformed, type_code: type_code, address: address,
                           fields: {}, raw: raw, findings: findings)
      end

      code = contents[0]
      payload = contents[1..] || ""
      kind, fields = case code
                     when "A" then decode_write_text(payload, findings)
                     when "G" then decode_write_string(payload, findings)
                     when "I" then decode_write_dots(payload, findings)
                     when "E" then decode_special(payload, findings)
                     when "B", "F", "H", "J" then [:read_request, { command: code, payload: payload }]
                     else
                       # Manual section 6: "unrecognised commands that are
                       # still correctly constructed will be ignored and
                       # will not result in any error reporting."
                       findings << Finding.new(severity: :warning, offset: 0,
                                               message: "command code #{code.inspect} isn't one XDF acts on; the sign ignores it silently")
                       [:unknown, { command: code, payload: payload }]
                     end

      Command.new(kind: kind, type_code: type_code, address: address,
                  fields: fields, raw: raw, findings: findings)
    end

    # "A" <label> <ESC> <position> <effect> <text...>
    def decode_write_text(payload, findings)
      label = payload[0]
      if label.nil?
        findings << Finding.new(severity: :error, offset: 0, message: "Write Text with no file label")
        return [:write_text, {}]
      end

      rest = payload[1..] || ""
      position = effect = extended_effect = nil

      if rest[0] == ESC.chr
        position_byte = rest.getbyte(1)
        effect_byte = rest.getbyte(2)
        position = POSITION_CODES[position_byte]
        if position.nil?
          findings << Finding.new(severity: :error, offset: 2,
                                  message: "position code #{hex(position_byte)} isn't one of XDF's four " \
                                           "(20H middle, 22H top, 26H bottom, 30H fill)")
        end
        unless EFFECT_CODES.include?(effect_byte)
          findings << Finding.new(severity: :error, offset: 3,
                                  message: "effect code #{hex(effect_byte)} is outside the documented range 61H-78H")
        end
        effect = effect_byte&.chr
        consumed = 3
        if effect_byte == EXTENDED_EFFECT_TRIGGER
          extended_effect = rest[3]
          unless EXTENDED_EFFECT_CODES.include?(extended_effect)
            findings << Finding.new(severity: :error, offset: 4,
                                    message: "effect \"n\" invokes an extended effect, but #{extended_effect.inspect} isn't a documented extended code")
          end
          consumed = 4
        end
        rest = rest[consumed..] || ""
      else
        findings << Finding.new(severity: :warning, offset: 1,
                                message: "no ESC position/effect sequence - the sign keeps whatever it last used for this file")
      end

      [:write_text, {
        label: label, position: position, effect: effect, extended_effect: extended_effect,
        content: decode_text_content(rest, findings)
      }]
    end

    # Walks message text, checking every control code has the parameters
    # the manual says it takes.
    def decode_text_content(text, findings, context: "message text")
      runs = []
      i = 0
      literal = +""

      flush = lambda do
        runs << { type: :text, value: literal.dup } unless literal.empty?
        literal.clear
      end

      while i < text.length
        byte = text.getbyte(i)
        char = text[i]

        if byte >= 0x20 || byte == 0x0A
          literal << char
          i += 1
          next
        end

        params = CONTROL_PARAMS[byte]
        if params.nil?
          findings << Finding.new(severity: :error, offset: i,
                                  message: "#{hex(byte)} in #{context} is not a control code XDF defines (Appendix A)")
          i += 1
          next
        end

        if i + params >= text.length + (params.zero? ? 1 : 0) && params.positive?
          findings << Finding.new(severity: :error, offset: i,
                                  message: "control code #{hex(byte)} needs #{params} parameter byte(s) but the message ends")
          break
        end

        argument = params.positive? ? text[i + 1, params] : nil
        flush.call
        runs << control_run(byte, argument, i, findings, context)
        i += 1 + params
      end

      flush.call
      runs
    end

    def control_run(byte, argument, offset, findings, context)
      case byte
      when 0x1C
        unless COLOUR_CODES.include?(argument)
          findings << Finding.new(severity: :error, offset: offset + 1,
                                  message: "colour code #{argument.inspect} isn't in XDF's table (section 21)")
        end
        { type: :colour, value: argument }
      when 0x1A
        unless CHARSET_CODES.include?(argument)
          # Section 14: "any unrecognised code always selects standard 7
          # high characters with XDF" - tolerated, so not an error.
          findings << Finding.new(severity: :warning, offset: offset + 1,
                                  message: "character set code #{argument.inspect} isn't documented; the sign falls back to 7 high standard")
        end
        { type: :charset, value: argument }
      when 0x10
        if context == "string file"
          # Section on String files: a String cannot call another String.
          findings << Finding.new(severity: :error, offset: offset,
                                  message: "a String file cannot call another String file")
        end
        { type: :call_string, label: argument }
      when 0x14
        { type: :call_dots, label: argument }
      when 0x0D then { type: :new_line }
      when 0x0C then { type: :new_page }
      when 0x09 then { type: :no_hold }
      when (0x15..0x19) then { type: :speed, value: byte - 0x14 }
      else
        { type: :control, code: format("%02X", byte), argument: argument }
      end
    end

    # "G" <label> <text...>
    def decode_write_string(payload, findings)
      label = payload[0]
      if label.nil?
        findings << Finding.new(severity: :error, offset: 0, message: "Write String with no file label")
        return [:write_string, {}]
      end

      [:write_string, {
        label: label,
        content: decode_text_content(payload[1..] || "", findings, context: "string file")
      }]
    end

    # "I" <label> <height 2 hex> <width 2 hex> then rows of pixel codes,
    # each terminated by one 0x0D.
    #
    # Section 13 gives the pixel codes ("0"-"8") and the storage accounting
    # - "picture area / 4, plus one byte per row, plus 13 byte overhead" -
    # which is where "one delimiter byte per row" comes from.
    def decode_write_dots(payload, findings)
      label = payload[0]
      height_hex = payload[1, 2]
      width_hex = payload[3, 2]

      unless label && height_hex&.length == 2 && width_hex&.length == 2 &&
             height_hex.match?(/\A[0-9A-Fa-f]{2}\z/) && width_hex.match?(/\A[0-9A-Fa-f]{2}\z/)
        findings << Finding.new(severity: :error, offset: 0,
                                message: "Write Dots header must be label + 2 hex digits of height + 2 hex digits of width")
        return [:write_dots, { label: label }]
      end

      height = height_hex.to_i(16)
      width = width_hex.to_i(16)
      # Section 13: "Dots Pictures are limited to 32 rows height and 255
      # columns width."
      findings << Finding.new(severity: :error, offset: 1, message: "height #{height} exceeds the 32-row maximum") if height > 32
      findings << Finding.new(severity: :error, offset: 3, message: "width #{width} exceeds the 255-column maximum") if width > 255

      rows = []
      data = payload[5..] || ""
      offset = 5
      cursor = 0

      height.times do |row_index|
        row = data[cursor, width]
        if row.nil? || row.length < width || row.include?("\r")
          # Count only what precedes the terminator: including the 0DH in
          # the tally would report a 3-pixel row as 4 and send whoever is
          # reading this off looking for the wrong thing.
          actual = row.to_s[/\A[^\r]*/].to_s.length
          findings << Finding.new(severity: :error, offset: offset + cursor,
                                  message: "row #{row_index} is #{actual} pixels but the header declares #{width}")
          break
        end

        row.each_char.with_index do |pixel, column|
          next if ("0".."8").cover?(pixel)

          findings << Finding.new(
            severity: :error, offset: offset + cursor + column,
            message: "pixel at row #{row_index}, column #{column} is #{pixel.inspect} " \
                     "(#{hex(pixel.ord)}); colour codes are \"0\"-\"8\" (section 13). " \
                     "If this is \"_\", something is sending a 2/3-byte escape inside a 1-byte frame."
          )
        end
        rows << row
        cursor += width

        terminator = data.getbyte(cursor)
        if terminator != 0x0D
          findings << Finding.new(
            severity: :error, offset: offset + cursor,
            message: "row #{row_index} ends with #{hex(terminator)}, not the 0DH that terminates a row"
          )
          break
        end
        cursor += 1
      end

      trailing = data[cursor..]
      if trailing && !trailing.empty?
        findings << Finding.new(severity: :warning, offset: offset + cursor,
                                message: "#{trailing.length} byte(s) after the last declared row")
      end

      [:write_dots, { label: label, height: height, width: width, rows: rows }]
    end

    # "E" <sub-code> <parameters>
    def decode_special(payload, findings)
      sub = payload[0]
      case sub
      when "$" then decode_memory_config(payload[1..] || "", findings)
      when nil
        findings << Finding.new(severity: :error, offset: 0, message: "Write Special Function with no sub-code")
        [:special, {}]
      else
        [:special, { sub_code: sub, payload: payload[1..] }]
      end
    end

    # Entries run back to back with no separator, each self-describing by
    # its own field widths:
    #   Text:   <label> "A" <L|U> <size 4 hex> <start 2 hex> <stop 2 hex>
    #   String: <label> "B" <L|U> <size 4 hex> "0000"
    #   Dots:   <label> "D" <L|U> <height 2 hex> <width 2 hex> <depth 4>
    def decode_memory_config(payload, findings)
      entries = []
      i = 0

      while i < payload.length
        label = payload[i]
        file_type = payload[i + 1]
        lock = payload[i + 2]

        unless %w[L U].include?(lock)
          findings << Finding.new(severity: :error, offset: i + 2,
                                  message: "memory config entry for #{label.inspect} has lock flag #{lock.inspect}, expected \"L\" or \"U\"")
          break
        end

        case file_type
        when "A"
          fields = payload[i + 3, 8]
          unless fields&.length == 8 && fields.match?(/\A[0-9A-Fa-f]{8}\z/)
            findings << Finding.new(severity: :error, offset: i + 3, message: "text file entry needs 4 hex size + 2 hex start + 2 hex stop")
            break
          end
          entries << { label: label, type: :text, locked: lock == "L", size: fields[0, 4].to_i(16),
                       start_time: fields[4, 2], stop_time: fields[6, 2] }
          i += 11
        when "B"
          fields = payload[i + 3, 8]
          unless fields&.length == 8 && fields.match?(/\A[0-9A-Fa-f]{8}\z/)
            findings << Finding.new(severity: :error, offset: i + 3, message: "string file entry needs 4 hex size followed by 0000")
            break
          end
          findings << Finding.new(severity: :warning, offset: i + 7, message: "string file entry's trailing field is #{fields[4, 4].inspect}, normally \"0000\"") unless fields[4, 4] == "0000"
          entries << { label: label, type: :string, locked: lock == "L", size: fields[0, 4].to_i(16) }
          i += 11
        when "D"
          fields = payload[i + 3, 8]
          unless fields&.length == 8
            findings << Finding.new(severity: :error, offset: i + 3, message: "dots file entry needs 2 hex height + 2 hex width + 4 char colour depth")
            break
          end
          height = fields[0, 2]
          width = fields[2, 2]
          depth = fields[4, 4]
          unless height.match?(/\A[0-9A-Fa-f]{2}\z/) && width.match?(/\A[0-9A-Fa-f]{2}\z/)
            findings << Finding.new(severity: :error, offset: i + 3, message: "dots entry height/width must be 2 hex digits each")
            break
          end
          # Section 13's colour depth table.
          unless %w[1000 2000 4000].include?(depth)
            findings << Finding.new(severity: :error, offset: i + 7,
                                    message: "colour depth #{depth.inspect} isn't one of \"1000\", \"2000\", \"4000\"")
          end
          entries << { label: label, type: :dots, locked: lock == "L",
                       height: height.to_i(16), width: width.to_i(16), depth: depth }
          i += 11
        else
          findings << Finding.new(severity: :error, offset: i + 1,
                                  message: "memory config file type #{file_type.inspect} isn't \"A\" (text), \"B\" (string) or \"D\" (dots)")
          break
        end
      end

      duplicates = entries.map { |e| e[:label] }.tally.select { |_, count| count > 1 }.keys
      duplicates.each do |label|
        findings << Finding.new(severity: :error, offset: 0,
                                message: "label #{label.inspect} appears more than once - a configuration defines each label exactly once")
      end

      [:memory_config, { entries: entries }]
    end

    def hex(byte)
      byte.nil? ? "(end of data)" : format("0x%02X", byte)
    end
  end
end
