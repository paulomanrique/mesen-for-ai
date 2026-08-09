from __future__ import annotations

import tempfile
import unittest
import zipfile
from pathlib import Path

from mesen_mcp.session import _extract_rom_from_zip


class ZipRomTests(unittest.TestCase):
    def test_extracts_single_supported_rom_member(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "game.zip"
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("docs/readme.txt", "not a rom")
                zf.writestr("nested/Game.sfc", b"rom bytes")

            extracted = _extract_rom_from_zip(archive, root / "session")

            self.assertEqual(extracted.name, "Game.sfc")
            self.assertEqual(extracted.read_bytes(), b"rom bytes")
            self.assertEqual(extracted.parent, root / "session")

    def test_rejects_zip_without_supported_rom(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "game.zip"
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("readme.txt", "not a rom")

            with self.assertRaisesRegex(ValueError, "no supported ROM"):
                _extract_rom_from_zip(archive, root / "session")

    def test_rejects_ambiguous_zip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "game.zip"
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("one.sfc", b"one")
                zf.writestr("two.sfc", b"two")

            with self.assertRaisesRegex(ValueError, "multiple supported ROM"):
                _extract_rom_from_zip(archive, root / "session")
