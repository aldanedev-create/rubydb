import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

import rubydb


@unittest.skipUnless(os.getenv("RUBYDB_LIVE_URL"), "set RUBYDB_LIVE_URL to run against a live RubyDB server")
class LiveRubyDBTests(unittest.TestCase):
    def test_parameterized_query_transaction_and_prepared_statement(self):
        with rubydb.connect(os.environ["RUBYDB_LIVE_URL"]) as connection:
            connection.autocommit = True
            with connection.cursor() as cursor:
                cursor.execute(
                    "CREATE TABLE IF NOT EXISTS python_adapter_smoke (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
                )
                cursor.execute("DELETE FROM python_adapter_smoke")
                cursor.execute("INSERT INTO python_adapter_smoke (name) VALUES (?)", ["python"])
                cursor.execute("SELECT name FROM python_adapter_smoke WHERE name = ?", ["python"])
                self.assertEqual(cursor.fetchone()["name"], "python")

            statement = connection.prepare("SELECT name FROM python_adapter_smoke WHERE name = ?")
            try:
                with statement.execute(["python"]) as cursor:
                    self.assertEqual(cursor.fetchone()["name"], "python")
            finally:
                statement.close()


if __name__ == "__main__":
    unittest.main()
