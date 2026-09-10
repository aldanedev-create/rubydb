import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[2] / "adapters" / "python" / "src"))

from flaxon.testing import TestClient

from app import app
from db import initialize_schema


@unittest.skipUnless(os.getenv("RUBYDB_URL"), "set RUBYDB_URL for live Flaxon tests")
class FlaxonRubyDBTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        initialize_schema()
        cls.client = TestClient(app)

    @classmethod
    def tearDownClass(cls):
        cls.client.close()

    def test_health_reads_real_rubydb(self):
        response = self.client.get("/rubydb-health")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])

    def test_create_and_list_note(self):
        created = self.client.post("/notes", json_data={"title": "Flaxon + RubyDB"})
        self.assertEqual(created.status_code, 201)
        self.assertEqual(created.json()["note"]["title"], "Flaxon + RubyDB")

        listed = self.client.get("/notes")
        self.assertEqual(listed.status_code, 200)
        self.assertTrue(
            any(note["title"] == "Flaxon + RubyDB" for note in listed.json()["notes"])
        )


if __name__ == "__main__":
    unittest.main()
