"""The wake word: what must wake the daemon and what must not (room talk that sounds alike)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import voice  # noqa: E402

CFG = dict(voice.DEFAULTS)

# What whisper writes when Bruno says "barch", alone or in front of a command.
WAKES = [
    "Barch.", "barch", "Bartch, abre o terminal", "Barque fecha a janela", "Bark", "Barsh, que horas são",
    "Baarch", "Barche", "Barrch", "Bar que horas são", "E aí barch, liga o HDR", "Ô barch", "Bach", "Bart",
    "Barch, coloca ele no workspace dois",
]
# Portuguese that only sounds alike, taken from a week of false wakes and the common vocabulary.
ROOM = [
    "parece que vai chover", "para que isso", "mas é claro", "base de dados", "parque", "mar", "marca",
    "marcha", "barco", "barato demais", "barra", "barriga", "match", "batch", "bate aqui", "par de",
    "mar que", "ma que", "cash", "dash", "parte dele", "bacana", "que você vai", "faz parte não deveria",
    "lindo", "raiva", "e isso", "engraçado velho", "pariu", "novo xô ver",
]


class Wake(unittest.TestCase):
    def test_wakes(self):
        for s in WAKES:
            yes, rest, _ = voice.wake_match(s, CFG)
            self.assertTrue(yes, s)
            self.assertNotIn("barch", rest, s)

    def test_rest_is_the_command(self):
        self.assertEqual(voice.wake_match("Bartch, abre o terminal", CFG)[1], "abre o terminal")
        self.assertEqual(voice.wake_match("E aí barch, liga o HDR", CFG)[1], "liga o hdr")
        self.assertEqual(voice.wake_match("Barch.", CFG)[1], "")

    def test_room_talk_does_not_wake(self):
        for s in ROOM:
            yes, _, _ = voice.wake_match(s, CFG)
            self.assertFalse(yes, s)

    def test_near_miss_score(self):
        # "barco" is close enough to be logged for tuning, "parece" is not
        self.assertGreaterEqual(voice.wake_match("barco", CFG)[2], voice.NEAR_MISS)
        self.assertLess(voice.wake_match("mano", CFG)[2], voice.NEAR_MISS)

    def test_config_spellings_are_exact(self):
        cfg = dict(CFG, wake=["barch", "zzz"])
        self.assertTrue(voice.wake_match("zzz abre", cfg)[0])
        self.assertFalse(voice.wake_match("zzy abre", cfg)[0])


class YesNo(unittest.TestCase):
    def test_stray_answers(self):
        self.assertIs(voice.yes_no("sim"), True)
        self.assertIs(voice.yes_no("não"), False)
        self.assertIsNone(voice.yes_no("abre o terminal"))


if __name__ == "__main__":
    unittest.main()
