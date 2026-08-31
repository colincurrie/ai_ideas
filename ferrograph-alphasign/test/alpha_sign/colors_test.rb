require "test_helper"

module AlphaSign
  class ColorsTest < Minitest::Test
    def test_named_color_lookup
      assert_equal Colors::RED, Colors.lookup("red")
      assert_equal Colors::RED, Colors.lookup("RED")
    end

    def test_unknown_named_color_raises
      assert_raises(ArgumentError) { Colors.lookup("plaid") }
    end

    def test_rgb_hex
      assert_equal "\x1CZFF00AA", Colors.rgb("ff00aa")
      assert_equal "\x1CZFF00AA", Colors.rgb("#ff00aa")
    end

    def test_rgb_hex_via_lookup
      assert_equal "\x1CZFF00AA", Colors.lookup("#FF00AA")
    end

    def test_rgb_rejects_invalid_hex
      assert_raises(ArgumentError) { Colors.rgb("nothex") }
    end

    def test_shadow_rgb
      assert_equal "\x1CY112233", Colors.shadow_rgb("112233")
    end
  end
end
