require "test_helper"
require_relative "../../serial_api/layout"

module SerialApi
  class LayoutTest < Minitest::Test
    def setup
      @layout = Layout.new
    end

    # XDF's power-on default already gives us a text file per label, so
    # configuring memory for text alone would blank the sign for nothing.
    def test_text_alone_needs_no_memory_configuration
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      refute @layout.custom_config_required?
      assert_nil @layout.memory_config
      refute @layout.needs_reconfiguration?
    end

    def test_a_string_forces_a_configuration_that_still_covers_the_text_files
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.put_string("1", text: "WORLD")
      assert @layout.needs_reconfiguration?

      contents = @layout.memory_config.contents
      assert_includes contents, "AA", "the text file must stay in the configuration"
      assert_includes contents, "1BL0100", "the string file gets a 256-byte reservation"
    end

    def test_marking_configured_settles_the_layout
      @layout.put_string("1", text: "WORLD")
      assert @layout.needs_reconfiguration?
      @layout.mark_configured!
      refute @layout.needs_reconfiguration?
    end

    # The reason sizes are bucketed: ordinary edits must not blank the sign.
    def test_editing_text_within_its_size_bucket_does_not_reconfigure
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.put_string("1", text: "WORLD")
      @layout.mark_configured!

      @layout.put_text("A", runs: [{ text: "HELLO AGAIN, WORLD" }])
      refute @layout.needs_reconfiguration?
    end

    def test_growing_past_the_bucket_does_reconfigure
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.put_string("1", text: "WORLD")
      @layout.mark_configured!

      @layout.put_text("A", runs: [{ text: "X" * (Layout::SIZE_GRANULARITY + 1) }])
      assert @layout.needs_reconfiguration?
    end

    def test_adding_an_image_reconfigures
      @layout.put_string("1", text: "WORLD")
      @layout.mark_configured!
      @layout.put_dots("P", width: 2, height: 1, pixels: "10")
      assert @layout.needs_reconfiguration?
      assert_includes @layout.memory_config.contents, "PD"
    end

    # After a configuration erases everything, every file has to be
    # rewritten - that is what stops an image from blanking the message.
    def test_content_packets_cover_every_file
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.put_string("1", text: "WORLD")
      @layout.put_dots("P", width: 2, height: 1, pixels: "10")

      written = @layout.content_packets(type: "a", address: "01").map(&:to_s).join
      assert_includes written, "AA"
      assert_includes written, "G1WORLD"
      assert_includes written, "IP0102"
    end

    def test_dots_pixels_are_split_into_rows_by_width
      @layout.put_dots("P", width: 2, height: 2, pixels: "1023")
      assert_includes @layout.dots_file("P").contents, "10_0D23_0D"
    end

    def test_delete_removes_a_file_and_can_drop_the_configuration_entirely
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.put_dots("P", width: 1, height: 1, pixels: "1")
      assert @layout.custom_config_required?

      @layout.delete(:dots, "P")
      refute @layout.custom_config_required?
      assert_equal({ "A" => { runs: [{ text: "HELLO" }], position: nil, mode: nil, speed: nil } },
                   @layout.to_h[:text])
    end

    # A memory configuration lists each label once with a type, so the same
    # label being two different file types would emit contradictory entries.
    def test_a_label_cannot_be_two_file_types_at_once
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      error = assert_raises(ArgumentError) { @layout.put_dots("A", width: 1, height: 1, pixels: "1") }
      assert_match(/already in use by a text file/, error.message)
      assert_empty @layout.dots
    end

    def test_a_label_can_be_reused_once_the_other_file_is_deleted
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.delete(:text, "A")
      @layout.put_dots("A", width: 1, height: 1, pixels: "1")
      assert_includes @layout.dots, "A"
    end

    def test_rewriting_a_file_with_its_own_label_is_fine
      @layout.put_text("A", runs: [{ text: "HELLO" }])
      @layout.put_text("A", runs: [{ text: "AGAIN" }])
      assert_equal [{ text: "AGAIN" }], @layout.text["A"].runs
    end

    def test_delete_rejects_an_unknown_kind
      assert_raises(ArgumentError) { @layout.delete(:nonsense, "A") }
    end

    def test_to_h_omits_bulky_pixel_data
      @layout.put_dots("P", width: 2, height: 1, pixels: "10")
      assert_equal({ "P" => { width: 2, height: 1 } }, @layout.to_h[:dots])
    end
  end
end
