require "test_helper"
require_relative "../../tools/fake_sign/decoder"

module FakeSign
  class DecoderTest < Minitest::Test
    def decode(contents, type: "Z", address: "00")
      frame = "\x00\x00\x00\x00\x00\x01#{type}#{address}\x02#{contents}\x04"
      Decoder.new.feed(frame)
    end

    def only(contents)
      commands = decode(contents)
      assert_equal 1, commands.size, "expected exactly one command"
      commands.first
    end

    def errors(command)
      command.findings.select { |f| f.severity == :error }.map(&:message)
    end

    def warnings(command)
      command.findings.select { |f| f.severity == :warning }.map(&:message)
    end

    # --- framing ---

    def test_decodes_a_frame_and_its_header
      command = only("AA\x1B\x30oHI")
      assert_equal :write_text, command.kind
      assert_equal "Z", command.type_code
      assert_equal "00", command.address
      assert command.ok?
    end

    def test_wake_up_padding_before_soh_is_skipped
      assert_equal 1, decode("AA\x1B\x30oHI").size
    end

    def test_several_frames_in_one_chunk
      decoder = Decoder.new
      frame = "\x00\x00\x00\x00\x00\x01Z00\x02G1HI\x04"
      commands = decoder.feed(frame * 3)
      assert_equal 3, commands.size
      assert(commands.all? { |c| c.kind == :write_string })
    end

    # Bytes arrive off a serial port in whatever chunks the UART feels like.
    def test_a_frame_split_across_feeds_is_held_until_complete
      decoder = Decoder.new
      assert_empty decoder.feed("\x00\x01Z00\x02AA\x1B\x30oHEL")
      commands = decoder.feed("LO\x04")
      assert_equal 1, commands.size
      assert_equal [{ type: :text, value: "HELLO" }], commands.first.fields[:content]
    end

    def test_a_two_byte_format_frame_is_flagged_not_guessed_at
      commands = Decoder.new.feed("\x5D\x21Z00\x02AAHI\x04")
      assert_equal :unsupported_format, commands.first.kind
      assert_match(/2-byte control format/, warnings(commands.first).first)
    end

    def test_a_valid_checksum_passes_and_a_wrong_one_is_caught
      body = "\x02G1HI\x03"
      good = format("%04X", body.bytes.sum & 0xFFFF)
      assert_empty errors(Decoder.new.feed("\x01Z00#{body}#{good}\x04").first)

      bad = Decoder.new.feed("\x01Z00#{body}FFFF\x04").first
      assert_match(/checksum FFFF doesn't match/, errors(bad).first)
    end

    # --- text files ---

    def test_decodes_position_effect_and_runs
      command = only("AA\x1B\x20b\x1C1RED\x1C2GREEN")
      assert_equal :middle, command.fields[:position]
      assert_equal "b", command.fields[:effect]
      assert_equal [
        { type: :colour, value: "1" },
        { type: :text, value: "RED" },
        { type: :colour, value: "2" },
        { type: :text, value: "GREEN" }
      ], command.fields[:content]
      assert command.ok?
    end

    def test_rejects_a_position_code_xdf_does_not_have
      # Alpha 3.0's left/right position codes, which the manual says XDF
      # does not support "and never will".
      command = only("AA\x1B\x29bHI")
      assert_match(/position code 0x29 isn't one of XDF's four/, errors(command).first)
    end

    def test_rejects_an_effect_code_outside_the_documented_range
      command = only("AA\x1B\x30ZHI")
      assert_match(/effect code 0x5A is outside the documented range/, errors(command).first)
    end

    def test_extended_effect_consumes_its_code
      command = only("AA\x1B\x30n0TWINKLE")
      assert_equal "n", command.fields[:effect]
      assert_equal "0", command.fields[:extended_effect]
      assert_equal [{ type: :text, value: "TWINKLE" }], command.fields[:content]
      assert command.ok?
    end

    def test_rejects_an_undocumented_extended_effect_code
      command = only("AA\x1B\x30n!HI")
      assert_match(/isn't a documented extended code/, errors(command).first)
    end

    def test_rejects_a_colour_code_outside_the_table
      command = only("AA\x1B\x30o\x1CzHI")
      assert_match(/colour code "z" isn't in XDF's table/, errors(command).first)
    end

    # Section 14: "any unrecognised code always selects standard 7 high
    # characters with XDF" - the sign copes, so this is not an error.
    def test_an_unknown_character_set_is_a_warning_because_the_sign_falls_back
      command = only("AA\x1B\x30o\x1AzHI")
      assert_empty errors(command)
      assert_match(/falls back to 7 high standard/, warnings(command).first)
    end

    def test_flags_a_control_code_xdf_does_not_define
      command = only("AA\x1B\x30oHI\x05THERE")
      assert_match(/0x05 in message text is not a control code XDF defines/, errors(command).first)
    end

    def test_flags_a_control_code_whose_parameter_is_missing
      command = only("AA\x1B\x30oHI\x1C")
      assert_match(/needs 1 parameter byte\(s\) but the message ends/, errors(command).first)
    end

    def test_decodes_calls_to_other_files
      command = only("AA\x1B\x30oNOW \x14P\x101")
      assert_includes command.fields[:content], { type: :call_dots, label: "P" }
      assert_includes command.fields[:content], { type: :call_string, label: "1" }
    end

    def test_missing_escape_sequence_is_a_warning
      command = only("AAHELLO")
      assert_empty errors(command)
      assert_match(/no ESC position\/effect sequence/, warnings(command).first)
    end

    # --- string files ---

    def test_decodes_a_string_file
      command = only("G1HELLO")
      assert_equal :write_string, command.kind
      assert_equal "1", command.fields[:label]
      assert command.ok?
    end

    def test_a_string_calling_another_string_is_rejected
      command = only("G1PART \x102")
      assert_match(/String file cannot call another String file/, errors(command).first)
    end

    # --- dots pictures ---

    def test_decodes_a_dots_picture
      command = only("IQ0202" + "12\r" + "30\r")
      assert_equal :write_dots, command.kind
      assert_equal({ label: "Q", height: 2, width: 2, rows: %w[12 30] }, command.fields)
      assert command.ok?
    end

    # THE REGRESSION THIS DECODER EXISTS FOR.
    #
    # This project sent "_0D" - the 3-byte format's escape for 0x0D - as a
    # row terminator inside 1-byte frames, where "_" is just an underscore.
    # Every unit test passed, because they all asserted the same bytes the
    # encoder produced. The sign showed the picture's top row and nothing
    # else. A decoder written from the manual catches it on sight.
    def test_catches_the_row_terminator_bug_this_project_actually_shipped
      command = only("IQ0808" + (["20000001"] * 8).map { |row| "#{row}_0D" }.join)
      assert_match(/row 0 ends with 0x5F, not the 0DH that terminates a row/, errors(command).first)
      assert_equal ["20000001"], command.fields[:rows],
                   "and it reproduces the symptom: one row decoded, the rest lost"
    end

    def test_flags_a_pixel_that_is_not_a_colour_code
      command = only("IQ0102" + "1X\r")
      assert_match(/column 1 is "X".*colour codes are "0"-"8"/m, errors(command).first)
    end

    def test_the_underscore_hint_names_the_likely_cause
      command = only("IQ0102" + "1_\r")
      assert_match(/2\/3-byte escape inside a 1-byte frame/, errors(command).first)
    end

    def test_flags_a_row_shorter_than_the_declared_width
      command = only("IQ0108" + "123\r")
      assert_match(/row 0 is 3 pixels but the header declares 8/, errors(command).first)
    end

    def test_rejects_a_picture_taller_than_the_hardware_allows
      command = only("IQ2102" + ("00\r" * 33))
      assert_match(/height 33 exceeds the 32-row maximum/, errors(command).first)
    end

    def test_rejects_a_malformed_dots_header
      assert_match(/header must be label \+ 2 hex digits/, errors(only("IQzz02" + "00\r")).first)
    end

    # --- memory configuration ---

    def test_decodes_each_entry_type
      command = only("E$AAU0100FFFF1BL010000 00QDU08082000".delete(" "))
      assert_equal :memory_config, command.kind
      types = command.fields[:entries].map { |e| [e[:label], e[:type]] }
      assert_equal [["A", :text], ["1", :string], ["Q", :dots]], types
      assert_equal 256, command.fields[:entries].first[:size]
      assert_equal({ label: "Q", type: :dots, locked: false, height: 8, width: 8, depth: "2000" },
                   command.fields[:entries].last)
      assert command.ok?
    end

    def test_rejects_an_unknown_colour_depth
      command = only("E$QDU08083000")
      assert_match(/colour depth "3000" isn't one of/, errors(command).first)
    end

    def test_rejects_an_unknown_file_type
      command = only("E$QZU08082000")
      assert_match(/file type "Z" isn't "A" \(text\), "B" \(string\) or "D" \(dots\)/, errors(command).first)
    end

    def test_rejects_a_bad_lock_flag
      command = only("E$QDX08082000")
      assert_match(/lock flag "X", expected "L" or "U"/, errors(command).first)
    end

    # A label is one namespace across all three file types, so a
    # configuration naming one twice is contradictory.
    def test_rejects_a_label_defined_twice
      command = only("E$AAU0100FFFFADU08082000")
      assert_match(/label "A" appears more than once/, errors(command).first)
    end

    # --- other commands ---

    def test_read_requests_are_recognised
      assert_equal :read_request, only("F$").kind
      assert_equal :read_request, only("BA").kind
    end

    # Section 6: "unrecognised commands that are still correctly
    # constructed will be ignored and will not result in any error
    # reporting" - so this is the sign's behaviour, not a protocol error.
    def test_an_unknown_command_code_is_a_warning
      command = only("ZZZ")
      assert_equal :unknown, command.kind
      assert_empty errors(command)
      assert_match(/the sign ignores it silently/, warnings(command).first)
    end
  end
end
