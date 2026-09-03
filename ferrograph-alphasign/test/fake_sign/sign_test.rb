require "test_helper"
require_relative "../../tools/fake_sign/decoder"
require_relative "../../tools/fake_sign/sign"
require_relative "../../tools/fake_sign/renderer"

module FakeSign
  class SignTest < Minitest::Test
    def setup
      @sign = Sign.new
      @decoder = Decoder.new
    end

    def send!(contents)
      frame = "\x00\x00\x00\x00\x00\x01Z00\x02#{contents}\x04"
      @decoder.feed(frame).flat_map { |command| @sign.apply(command) }
    end

    def errors(findings)
      findings.select { |f| f.severity == :error }.map(&:message)
    end

    # Section 11: with no configuration sent, XDF defines one text file per
    # memory page, labels from "A" - five of them on a 128K machine.
    def test_starts_on_the_default_configuration
      assert_equal %w[A B C D E], @sign.files.keys
      assert(@sign.files.values.all? { |f| f[:type] == :text })
      assert_equal 11, Sign.new(memory_kb: 256).files.size
    end

    def test_writing_to_a_default_text_file_works
      assert_empty errors(send!("AA\x1B\x30oHELLO"))
      assert_equal ["A"], @sign.run_sequence
    end

    # The web app offers labels A-Z, but a sign on its default
    # configuration only has as many as it has memory pages.
    def test_writing_beyond_the_default_labels_is_rejected_the_way_the_sign_would
      messages = errors(send!("AM\x1B\x30oHELLO"))
      assert_match(/no file "M" is defined/, messages.first)
      assert_match(/memory allocation failure/, messages.first)
      assert_match(/A, B, C, D, E on a 128K machine/, messages.first)
      assert_empty @sign.run_sequence
    end

    def test_a_picture_needs_a_configuration_that_defines_it
      assert_match(/no file "Q" is defined/, errors(send!("IQ0202" + "12\r30\r")).first)
    end

    # The behaviour behind the blank-screen bug: configuring memory erases
    # everything, so a text file written beforehand is gone.
    def test_configuring_memory_erases_every_file
      send!("AA\x1B\x30oHELLO")
      assert_equal ["A"], @sign.run_sequence

      send!("E$AAU0100FFFFQDU02022000")
      assert_empty @sign.run_sequence, "the text file's contents went with the reconfiguration"
      assert_equal %w[A Q], @sign.files.keys
    end

    def test_writing_the_wrong_file_type_to_a_label_is_rejected
      send!("E$QDU02022000")
      assert_match(/defined as a dots file, but this is a text write/, errors(send!("AQ\x1B\x30oHI")).first)
    end

    def test_a_picture_bigger_than_its_reservation_is_rejected_and_not_stored
      send!("E$QDU02022000")
      assert_match(/picture is 4x4 but the configuration reserved 2x2/, errors(send!("IQ0404" + (["1230"] * 4).map { |r| "#{r}\r" }.join)).first)
      refute @sign.files["Q"][:updated]
    end

    def test_only_text_files_with_content_enter_the_run_sequence
      send!("E$AAU0100FFFFBAU0100FFFFQDU02022000")
      send!("AB\x1B\x30oSECOND")
      send!("IQ0202" + "12\r30\r")
      assert_equal ["B"], @sign.run_sequence, "A was defined but never written; Q is a picture"
    end

    def test_reports_what_it_holds
      send!("E$AAU0100FFFFQDU02022000")
      send!("AA\x1B\x30oHI \x14Q")
      send!("IQ0202" + "12\r30\r")

      state = @sign.to_h
      assert_equal ["A"], state[:run_sequence]
      assert_equal "HI [image Q]", state[:files]["A"][:preview]
      assert_equal "2x2", state[:files]["Q"][:dimensions]
    end
  end

  class RendererTest < Minitest::Test
    def setup
      @sign = Sign.new
      @decoder = Decoder.new
      send!("E$AAU0100FFFFQDU0202200011BL01000000".sub("11BL", "1BL"))
    end

    def send!(contents)
      @decoder.feed("\x01Z00\x02#{contents}\x04").each { |c| @sign.apply(c) }
    end

    def frame
      Renderer.new(@sign).frames.first[:pixels]
    end

    def lit(pixels)
      pixels.flatten.count { |c| c != 0 }
    end

    def test_a_text_file_with_no_content_produces_no_frame
      assert_empty Renderer.new(@sign).frames
    end

    def test_renders_text_in_the_requested_colour
      send!("AA\x1B\x20b\x1C2HI")
      pixels = frame
      assert_operator lit(pixels), :>, 0
      assert_equal [2], pixels.flatten.reject(&:zero?).uniq, "every lit pixel should be green"
    end

    def test_renders_a_called_picture_at_its_own_colours
      send!("IQ0202" + "12\r30\r")
      send!("AA\x1B\x20b\x14Q")
      pixels = frame
      # 1 red, 2 green, 3 yellow - the picture's own codes, not the text's.
      assert_includes pixels.flatten, 3
      assert_includes pixels.flatten, 2
    end

    # The bug that started all this: a picture stored but never called
    # displays nothing at all.
    def test_a_picture_that_no_message_calls_does_not_appear
      send!("IQ0202" + "12\r30\r")
      send!("AA\x1B\x20bHI")
      refute_includes frame.flatten, 3, "the picture's yellow pixel must not be on screen"
    end

    def test_a_called_string_is_drawn_inline
      send!("G1WORLD")
      send!("AA\x1B\x20b\x101")
      assert_operator lit(frame), :>, 0
    end

    # Section 17: the four position codes put 7-high text in different rows.
    def test_position_moves_the_text
      send!("AA\x1B\x22bH")  # top
      top_rows = frame.each_with_index.select { |row, _| row.any? { |c| c != 0 } }.map(&:last)
      assert_equal 0, top_rows.min

      send!("AA\x1B\x26bH")  # bottom
      bottom_rows = frame.each_with_index.select { |row, _| row.any? { |c| c != 0 } }.map(&:last)
      assert_equal 15, bottom_rows.max
    end

    def test_the_frame_is_the_size_of_the_display
      send!("AA\x1B\x20bHI")
      pixels = frame
      assert_equal 16, pixels.size
      assert_equal 135, pixels.first.size
    end
  end
end
