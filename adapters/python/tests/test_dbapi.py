import json
import socket
import threading
import unittest

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

import rubydb


def envelope(message_type, payload):
    return {
        "type": message_type,
        "id": "server-message",
        "created_at": "2026-01-01T00:00:00Z",
        "payload": payload,
        "compressed": False,
        "encrypted": False,
        "checksum": None,
    }


class FakeRubyDBServer:
    def __init__(self, query_result=None):
        self.query_result = query_result or {
            "columns": [{"name": "id", "type": "integer"}],
            "rows": [{"id": 1}],
            "row_count": 1,
            "affected_rows": 0,
        }
        self.received = []
        self.ready = threading.Event()
        self.finished = threading.Event()
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.port = self.server.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()
        self.ready.wait(2)
        return self

    def stop(self):
        try:
            self.server.close()
        finally:
            self.finished.wait(2)
            self.thread.join(2)

    def send(self, connection, message_type, payload):
        data = json.dumps(envelope(message_type, payload), separators=(",", ":"))
        connection.sendall((data + "\n").encode("utf-8"))

    def receive(self, reader):
        line = reader.readline()
        if not line:
            raise EOFError("client disconnected")
        value = json.loads(line.decode("utf-8"))
        self.received.append(value)
        return value

    def run(self):
        self.ready.set()
        try:
            connection, _ = self.server.accept()
            with connection:
                reader = connection.makefile("rb")
                handshake = self.receive(reader)
                self.send(connection, "handshake_response", {"success": True, "default_auth": "none"})
                auth = self.receive(reader)
                self.send(connection, "authentication", {"success": True})
                sync = self.receive(reader)
                self.send(connection, "ready_for_query", {"success": True})
                while True:
                    request = self.receive(reader)
                    payload = request.get("payload", {})
                    request_type = request.get("type")
                    if request_type == "terminate":
                        return
                    if request_type == "query":
                        self.send(connection, "query_response", {
                            "success": True,
                            "result": self.query_result,
                            "request_id": request.get("id"),
                        })
                    elif request_type == "begin":
                        self.send(connection, "begin_response", {"success": True, "transaction_id": "txn-1"})
                    elif request_type == "commit":
                        self.send(connection, "commit_response", {"success": True, "committed": True})
                    elif request_type == "rollback":
                        self.send(connection, "rollback_response", {"success": True, "rolled_back": True})
                    elif request_type == "ping":
                        self.send(connection, "ping_response", {"success": True, "pong": True})
                    elif request_type == "prepare":
                        self.send(connection, "prepare_response", {"success": True, "statement_id": "stmt-1"})
                    elif request_type == "execute":
                        self.send(connection, "execute_response", {
                            "success": True,
                            "result": self.query_result,
                            "request_id": request.get("id"),
                        })
                    elif request_type == "close":
                        self.send(connection, "close_response", {"success": True})
                    else:
                        self.send(connection, request_type + "_response", {"success": True, "result": {}})
        except (OSError, EOFError):
            pass
        finally:
            self.finished.set()


class RubyDBApiTests(unittest.TestCase):
    def test_connect_query_and_parameter_transport(self):
        server = FakeRubyDBServer().start()
        try:
            url = "rubydb://rubydb@127.0.0.1:%d/app" % server.port
            with rubydb.connect(url) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT id FROM users WHERE active = ?", [True])
                    self.assertEqual(cursor.fetchone(), {"id": 1})
                    self.assertEqual(cursor.description[0][0], "id")
            query = next(item for item in server.received if item["type"] == "query")
            self.assertEqual(query["payload"]["params"], [True])
        finally:
            server.stop()

    def test_context_commits_lazy_transaction(self):
        server = FakeRubyDBServer({"rows": [], "row_count": 0, "affected_rows": 1}).start()
        try:
            with rubydb.connect("rubydb://127.0.0.1:%d/app" % server.port) as connection:
                connection.execute("INSERT INTO events (name) VALUES (?)", ["boot"])
            request_types = [item["type"] for item in server.received]
            self.assertIn("begin", request_types)
            self.assertIn("query", request_types)
            self.assertIn("commit", request_types)
        finally:
            server.stop()

    def test_prepared_statement_round_trip(self):
        server = FakeRubyDBServer().start()
        try:
            with rubydb.connect("rubydb://127.0.0.1:%d/app" % server.port) as connection:
                statement = connection.prepare("SELECT id FROM users WHERE id = ?")
                with statement.execute([1]) as cursor:
                    self.assertEqual(cursor.fetchall(), [{"id": 1}])
                statement.close()
            request_types = [item["type"] for item in server.received]
            self.assertIn("prepare", request_types)
            self.assertIn("execute", request_types)
            self.assertIn("close", request_types)
        finally:
            server.stop()

    def test_pool_rejects_invalid_limits(self):
        with self.assertRaises(rubydb.InterfaceError):
            rubydb.ConnectionPool("rubydb://127.0.0.1:7432/app", min_size=2, max_size=1)


if __name__ == "__main__":
    unittest.main()
