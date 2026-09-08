#!/usr/bin/env python3
"""Local mock OpenAI-compatible /chat/completions server for ziki e2e testing.

Returns a scripted sequence so the goal loop completes deterministically:
  1) a write_file tool call  -> ziki creates hello.txt
  2) "done" content           -> loop proceeds to verify (criterion is set)
  3) "YES ..." content        -> verifier confirms the criterion is satisfied
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

RESPONSES = [
    {  # 1) tool call
        "choices": [{
            "message": {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "write_file",
                                 "arguments": json.dumps({"path": "hello.txt",
                                                          "data": "hello from ziki"})},
                }],
            },
            "finish_reason": "tool_calls",
        }]
    },
    {  # 2) mild acknowledgement, loop moves to verification
        "choices": [{
            "message": {"role": "assistant", "content": "done", "tool_calls": None},
            "finish_reason": "stop",
        }]
    },
    {  # 3) verifier says YES
        "choices": [{
            "message": {"role": "assistant", "content": "YES the file exists",
                        "tool_calls": None},
            "finish_reason": "stop",
        }]
    },
]

idx = {"n": 0}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        body = RESPONSES[min(idx["n"], len(RESPONSES) - 1)]
        idx["n"] += 1
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8731), H).serve_forever()
