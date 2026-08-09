import unittest

from mesen_mcp.validation import Field, ValidationError, validate_args


class ValidationTests(unittest.TestCase):
    def test_unknown_argument_names_argument_suggestion_and_accepted(self) -> None:
        schema = {"session": Field(str, required=True), "frames": Field(int, required=True)}
        with self.assertRaises(ValidationError) as raised:
            validate_args("run.step_frames", schema, {"session": "s1", "frame": 1})

        message = str(raised.exception)
        self.assertIn("unknown argument 'frame'", message)
        self.assertIn("did you mean 'frames'", message)
        self.assertIn("accepted arguments: frames, session", message)


if __name__ == "__main__":
    unittest.main()
