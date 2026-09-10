import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "adapters" / "python" / "src"))

from app import create_app
from db import initialize_schema


@unittest.skipUnless(os.getenv("RUBYDB_URL"), "set RUBYDB_URL for live Flask tests")
class FlaskRubyDBTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        initialize_schema()
        cls.client = create_app().test_client()

    def test_health_reads_real_rubydb(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["ok"])

    def test_create_and_list_note(self):
        created = self.client.post("/notes", json={"title": "Flask + RubyDB"})
        self.assertEqual(created.status_code, 201)
        self.assertEqual(created.get_json()["note"]["title"], "Flask + RubyDB")

        listed = self.client.get("/notes")
        self.assertEqual(listed.status_code, 200)
        self.assertTrue(
            any(note["title"] == "Flask + RubyDB" for note in listed.get_json()["notes"])
        )


if __name__ == "__main__":
    unittest.main()
