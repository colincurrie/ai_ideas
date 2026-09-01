require "test_helper"

module AlphaSign
  class MemoryConfigTest < Minitest::Test
    def test_text_file_entry_format
      # label(1) type"A"(1) lock"U"/"L"(1) size(4 hex) start(2 hex) stop(2 hex)
      config = MemoryConfig.new.text_file("A", size: 256)
      assert_equal "E$AAU0100FFFF", config.contents
    end

    def test_text_file_locked
      config = MemoryConfig.new.text_file("A", size: 1, locked: true)
      assert_equal "E$AAL0001FFFF", config.contents
    end

    def test_dots_file_entry_format
      # label(1) type"D"(1) lock(1) height(2 hex) width(2 hex) depth(4 chars)
      config = MemoryConfig.new.dots_file("P", height: 16, width: 135)
      assert_equal "E$PDU10872000", config.contents
    end

    def test_dots_file_monochrome_depth
      config = MemoryConfig.new.dots_file("P", height: 1, width: 1, monochrome: true)
      assert_equal "E$PDU01011000", config.contents
    end

    def test_entries_concatenate_in_order
      config = MemoryConfig.new
                           .text_file("A", size: 256)
                           .dots_file("P", height: 2, width: 3)
      assert_equal "E$AAU0100FFFFPDU02032000", config.contents
    end

    def test_to_packet_wraps_contents
      config = MemoryConfig.new.text_file("A", size: 1)
      packet = config.to_packet
      assert_includes packet.to_s, config.contents
    end
  end
end
