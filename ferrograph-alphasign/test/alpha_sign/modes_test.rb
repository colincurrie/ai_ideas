require "test_helper"

module AlphaSign
  class ModesTest < Minitest::Test
    def test_basic_effect_codes_match_xdf_appendix_c
      assert_equal "a", Modes.lookup("rotate")
      assert_equal "b", Modes.lookup("hold")
      assert_equal "m", Modes.lookup("scroll")
      assert_equal "t", Modes.lookup("compressed_rotate")
    end

    def test_extended_effect_codes_match_xdf_appendix_d
      assert_equal "n0", Modes.lookup("twinkle")
      assert_equal "nC", Modes.lookup("colour_cycle")
      assert_equal "nX", Modes.lookup("vertical_explode_wipe")
    end

    def test_unknown_mode_raises
      assert_raises(ArgumentError) { Modes.lookup("nonsense") }
    end
  end
end
