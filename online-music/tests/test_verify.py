import unittest
from pathlib import Path

from verify import (
    ALLOWED_EXTS,
    build_filename,
    ext_allowed,
    is_lossless,
    media_type,
    normalize_ext,
    safe_component,
)


class VerifyHelpersTest(unittest.TestCase):
    def test_ext_normalization(self):
        self.assertEqual(normalize_ext(".FLAC"), "flac")
        self.assertEqual(normalize_ext(None), "")
        self.assertTrue(ext_allowed("m4a"))
        self.assertFalse(ext_allowed("ape"))
        self.assertTrue(is_lossless("flac"))
        self.assertFalse(is_lossless("mp3"))
        self.assertEqual(media_type("flac"), "audio/flac")

    def test_safe_component(self):
        self.assertEqual(safe_component("晴天", "未知"), "晴天")
        self.assertNotIn("/", safe_component("a/b", "未知"))
        self.assertNotIn("..", safe_component("..", "未知"))
        self.assertEqual(safe_component("", "未知"), "未知")

    def test_build_filename(self):
        self.assertEqual(build_filename("晴天", "周杰伦", ".flac"), "晴天 - 周杰伦.flac")
        self.assertEqual(build_filename("晴天", "", "mp3"), "晴天.mp3")
        name = build_filename("a" * 300, "b" * 300, "flac")
        self.assertLessEqual(len(name), 200)
        self.assertTrue(name.endswith(".flac"))

    def test_allowed_set_does_not_include_unsupported_formats(self):
        self.assertNotIn("ape", ALLOWED_EXTS)
        self.assertNotIn("wv", ALLOWED_EXTS)
        self.assertIn("aiff", ALLOWED_EXTS)


if __name__ == "__main__":
    unittest.main()
