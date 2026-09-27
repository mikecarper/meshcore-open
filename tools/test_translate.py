"""Offline regression tests for merged translation tools; no API calls."""
import contextlib
import io
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import translate


class TranslationMergeTests(unittest.TestCase):
    def test_template_copy_preserves_translations_and_metadata(self):
        self.assertEqual(
            translate.find_keys_still_template_copy(
                {"same": "Same", "done": "Save", "missing": "New", "@same": {}},
                {"same": "Same", "done": "Guardar"},
            ),
            ["same", "missing"],
        )

    def test_placeholder_validation_including_icu(self):
        source = "{count, plural, =1{item} other{items}} for {name}"
        valid, _ = translate.validate_preserved_tokens(
            source, "{count, plural, =1{elemento} other{elementos}} para {name}"
        )
        self.assertTrue(valid)
        self.assertFalse(translate.validate_preserved_tokens(source, "Wrong")[0])

    def test_manual_only_translation_does_not_require_model_output(self):
        args = SimpleNamespace(
            backend="ollama", host="unused", model="unused", timeout=1,
            temperature=0, num_ctx=128, num_predict=16, top_p=1,
            fallback_model=None, concurrency=1, retries=0, backoff=0,
            confidence_threshold=0.7, model_confidence_threshold=4,
            progress_every=0, retry_model=None, dry_run=True,
        )
        with patch.object(translate, "ollama_generate", side_effect=AssertionError("Network")), contextlib.redirect_stdout(io.StringIO()):
            count = translate.translate_locale(
                {"repeater_daysHoursMinsSecs": "{days} days"}, {},
                "fr", "French", "unused.arb", args, {},
            )
        self.assertEqual(count, 1)

    def test_fallback_uses_its_own_backend(self):
        result = translate.translate_one(
            "greeting", "Hello {name}", "French",
            lambda *_: "Invalid", SimpleNamespace(model="primary"),
            retries=0, backoff_s=0,
            fallback_generate_fn=lambda *_: "Bonjour {name}",
            fallback_config=SimpleNamespace(model="fallback"),
        )
        self.assertEqual(result, ("greeting", "Bonjour {name}", None, True))


if __name__ == "__main__":
    unittest.main()
