"""Complete ordinary Factory Commons games using loopback-only HTTP fixtures.

Use unique private output directories. Fixture calls are never teacher evidence.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def observe_globals(port, output, stop, failures):
    """Drain the actual viewer stream while checking ordinary-wait pongs."""
    from websockets.sync.client import connect

    records = []
    try:
        with connect(
            f"ws://127.0.0.1:{port}/global", max_size=1024 * 1024, max_queue=1024
        ) as live:
            packet = live.recv(timeout=3)
            assert isinstance(packet, bytes) and packet
            (output / "global-startup.bin").write_bytes(packet)
            records.append({"kind": "startup", "bytes": len(packet)})
            next_ping = time.monotonic()
            while not stop.wait(0.02):
                try:
                    packet = live.recv(timeout=0.02)
                except TimeoutError:
                    pass
                else:
                    assert isinstance(packet, bytes) and packet
                    if not (output / "global-first-frame.bin").exists():
                        (output / "global-first-frame.bin").write_bytes(packet)
                if time.monotonic() >= next_ping:
                    started = time.monotonic()
                    assert live.ping().wait(2), "viewer pong deadline"
                    for route in ("healthz", "client/global"):
                        with urllib.request.urlopen(
                            f"http://127.0.0.1:{port}/{route}", timeout=2
                        ) as response:
                            assert response.status == 200 and response.read(512)
                    records.append(
                        {
                            "kind": "pong-health-client",
                            "seconds": time.monotonic() - started,
                        }
                    )
                    next_ping = time.monotonic() + 1
    except Exception as error:  # noqa: BLE001 - thread errors must fail the system proof.
        if not stop.is_set() and not (output / "results.json").exists():
            failures.append(repr(error))
    finally:
        (output / "global-readiness.json").write_text(
            json.dumps({"checks": records, "failures": failures}, indent=2) + "\n"
        )


def measure(output, processes, calls, started):
    size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
    disk = shutil.disk_usage(output).free
    assert size <= 16 * 1024 * 1024, "per-game 16 MiB output guard"
    # The explicit evidence parent is the owned retained slice, including failures.
    aggregate = sum(p.stat().st_size for p in output.parent.rglob("*") if p.is_file())
    assert aggregate <= 256 * 1024 * 1024, "owned aggregate 256 MiB evidence guard"
    assert disk >= 2 * 1024**3, "2 GiB disk floor"
    assert time.monotonic() - started <= 360, "360-second game wall guard"
    row = {
        "elapsed_seconds": time.monotonic() - started,
        "artifact_bytes": size,
        "aggregate_artifact_bytes": aggregate,
        "controller_pid": os.getpid(),
        "disk_free_bytes": disk,
        "http_calls": len(calls),
        "HTTP_status_counts": {
            str(s): sum(c["status"] == s for c in calls)
            for s in {c["status"] for c in calls}
        },
        "response_bytes": sum(
            len(base64.b64decode(c["response_body_b64"])) for c in calls
        ),
        "owned_processes": [{"pid": p.pid, "returncode": p.poll()} for p in processes],
    }
    if processes:
        result = subprocess.run(
            [
                "ps",
                "-o",
                "pid=,rss=,time=",
                "-p",
                ",".join([str(os.getpid())] + [str(p.pid) for p in processes]),
            ],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        row["process_resources"] = result.stdout.splitlines()
    with (output / "metrics.jsonl").open("a") as handle:
        handle.write(json.dumps(row) + "\n")


def strict_object(text):
    def pairs(entries):
        result = {}
        for key, value in entries:
            key.encode("utf-8")
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def scalar(value):
        if isinstance(value, str):
            value.encode("utf-8")
        elif isinstance(value, float):
            import math

            if not math.isfinite(value):
                raise ValueError("nonfinite number")
        elif isinstance(value, dict):
            for child in value.values():
                scalar(child)
        elif isinstance(value, list):
            for child in value:
                scalar(child)

    value = json.loads(
        text[text.index("{") : text.rindex("}") + 1], object_pairs_hook=pairs
    )
    scalar(value)
    return value


def supplied_equal(raw, actual):
    if type(raw) is not type(actual):
        return False
    if isinstance(raw, dict):
        return all(
            key in actual and supplied_equal(value, actual[key])
            for key, value in raw.items()
        )
    return raw == actual


def check_evidence(output, calls, mode):
    # Strict UTF-8 decode is intentional. Forensic B64 is not model input or a label.
    records = [
        json.loads(line)
        for line in (output / "trajectory.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    for record in records:
        # Independent Python validation includes escaped lone surrogates and
        # nonfinite numbers, beyond merely decoding the file's UTF-8 bytes.
        json.dumps(record, ensure_ascii=False, allow_nan=False).encode("utf-8")
    decisions = [r for r in records if r["event_type"] == "decision"]
    assert len(decisions) == 45
    indexed = {c["call_id"]: c for c in calls}
    seen = set()
    forensic = 0
    unobserved = []
    statuses = {}
    for row in decisions:
        statuses[row["action_status"]] = statuses.get(row["action_status"], 0) + 1
        seat = int(row["seat"])
        observation = row["observation"]
        actual = row["executed_action"]
        attempts = row["attempts"]
        if "invalid_native_evidence_json_b64" in observation:
            assert row["action_status"] in {"rejected", "fallback"}
            assert (
                row["selected_attempt_id"] is None and actual is None and not attempts
            )
            original = base64.b64decode(observation["invalid_native_evidence_json_b64"])
            assert (
                base64.b64encode(original).decode()
                == observation["invalid_native_evidence_json_b64"]
            )
            restored = json.loads(original.decode("utf-8", "surrogateescape"))
            observation, attempts, actual = (
                restored["observation"],
                restored["attempts"],
                restored["executed_action"],
            )
            forensic += 1
        assert len(attempts) <= 2
        for index, attempt in enumerate(attempts):
            wire = observation["native_requests"][index]
            request_bytes = base64.b64decode(wire["body_b64"])
            cid = attempt["platform_call_id"]
            if cid is None:
                # The declared timeout has no response receipt, but its actual forwarded
                # request is still matched to the fixture's exact bytes and logical seat.
                candidates = [
                    c
                    for c in calls
                    if c["call_id"] not in seen
                    and c["slot"] == str(seat)
                    and base64.b64decode(c["request_body_b64"]) == request_bytes
                ]
                if not candidates:
                    # A concurrent batch can abort queued/pipeline-waiting requests
                    # before the sentinel sees them. Preserve this uncertainty;
                    # never fabricate a call ID, response or actual HTTP count.
                    assert mode == "mixed" and row["decision_id"] in {"1-1", "1-2"}
                    assert index == 0 and not attempt["response_complete"]
                    assert attempt["http_status"] is None and not attempt.get(
                        "accepted", False
                    )
                    assert attempt["request"] == json.loads(request_bytes)
                    assert wire["headers"]["X-Coworld-Player-Slot"] == str(seat)
                    unobserved.append(attempt["attempt_id"])
                    continue
                assert len(candidates) == 1
                call = candidates[0]
                cid = call["call_id"]
                assert not attempt.get("accepted", False)
                assert not attempt["response_complete"]
            else:
                call = indexed[cid]
                assert str(seat) == call["slot"]
                assert base64.b64decode(
                    attempt["response_body_b64"]
                ) == base64.b64decode(call["response_body_b64"])
                assert attempt["http_status"] == call["status"]
                headers = {k.lower(): v for k, v in attempt["response_headers"].items()}
                assert not (
                    {"authorization", "x-api-key", "cookie", "set-cookie"}
                    & headers.keys()
                )
                assert headers["x-softmax-llm-call-id"] == cid
            seen.add(cid)
            assert base64.b64decode(call["request_body_b64"]) == request_bytes
            if (
                attempt.get("accepted", False)
                and "invalid_native_evidence_json_b64" not in row["observation"]
            ):
                assert row["selected_attempt_id"] == attempt["attempt_id"]
                assert supplied_equal(strict_object(attempt["response"]), actual)
                assert attempt["parsed_action"] == actual
        for other in range(3):
            if other != seat:
                assert f"PRIVATE_SLOT_{other}_" not in json.dumps(observation)
        own_orders = [
            e
            for e in observation["native_execution"]["events"]
            if e["k"] == "order" and e["seat"] == seat
        ]
        assert len(own_orders) == 1
        assert {k: own_orders[0][k] for k in ["job", "cube", "say", "notes"]} == actual
    assert seen == set(indexed), "fixture attempts missing from private capture"
    if mode == "positive":
        assert statuses == {"accepted": 45}
    elif mode == "retry":
        assert len(calls) == 30 and statuses == {"accepted": 15, "missing": 30}
    elif mode == "throttle":
        assert len(calls) == 15 and statuses["fallback"] == 1
        assert [c["status"] for c in calls].count(429) == 1
    elif mode == "auth":
        assert len(calls) == 1 and statuses["fallback"] == 15
    elif mode == "mixed":
        assert statuses.get("accepted") and statuses.get("rejected")
        assert forensic == 0, "invalid orders entered native state before capture"
        for row in decisions:
            if row["decision_id"] in {
                f"{shift}-{seat}" for shift in [5, 7] for seat in range(3)
            }:
                assert row["action_status"] == "fallback"
                assert row["selected_attempt_id"] is None
    return {
        "decisions": len(decisions),
        "HTTP_attempts": len(seen),
        "statuses": statuses,
        "forensic_rows_excluded": forensic,
        "native_submitted_attempts_not_observed_by_sentinel": unobserved,
    }


def external_player(port, output, stop, failures):
    from websockets.sync.client import connect

    try:
        with connect(
            f"ws://127.0.0.1:{port}/player?slot=1&token=local-token-1"
        ) as player:
            player.send(json.dumps({"type": "register", "control": "external"}))
            while not stop.is_set():
                message = json.loads(player.recv(timeout=30))
                if message["type"] == "final":
                    return
                if message["type"] != "observation":
                    continue
                observation = message["observation"]
                order = {
                    "job": "maintain"
                    if observation["machine"]["integrity"] < 75
                    else "operate",
                    "cube": "blue",
                    "say": "external fixture",
                    "notes": "PRIVATE_SLOT_1_EXTERNAL",
                }
                action = {"type": "action", "shift": message["shift"], "action": order}
                with (output / "external-actions.jsonl").open("a") as handle:
                    handle.write(json.dumps(action) + "\n")
                player.send(json.dumps(action))
    except Exception as error:  # noqa: BLE001 - thread errors must fail the system proof.
        if not stop.is_set() and not (output / "results.json").exists():
            failures.append("external player: " + repr(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", default="factory-commons")
    parser.add_argument(
        "--mode",
        choices=[
            "positive",
            "retry",
            "throttle",
            "auth",
            "mixed",
            "external",
            "publication",
        ],
        default="positive",
    )
    parser.add_argument("--no-capture", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    (output / "harness-source.py").write_bytes(Path(__file__).read_bytes())
    sources = {
        str(p): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(Path("src").rglob("*.nim"))
    }
    (output / "source-bindings.json").write_text(json.dumps(sources, indent=2) + "\n")
    source_hash = hashlib.sha256(
        json.dumps(sources, sort_keys=True).encode()
    ).hexdigest()
    started = time.monotonic()
    calls, processes, logs, failures = [], [], [], []
    call_lock = threading.Lock()
    stop = threading.Event()
    fixture = None
    viewer = None
    summary = {"status": "failed", "fixture_only": True, "real_provider_calls": 0}

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_PUT(self):
            assert self.path == "/private-trajectory" and args.mode == "publication"
            data = self.rfile.read(int(self.headers["Content-Length"]))
            assert len(data) <= 12 * 1024 * 1024
            (output / "trajectory.jsonl").write_bytes(data)
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            if self.path == "/private-trajectory":
                return self.do_PUT()
            assert self.path == "/v1/messages"
            length = int(self.headers["Content-Length"])
            assert 0 < length <= 65536
            raw_bytes = self.rfile.read(length)
            received_seconds = time.monotonic() - started
            try:
                raw = raw_bytes.decode("utf-8")
            except UnicodeDecodeError:
                raw = None
            body = json.loads(raw_bytes.decode("utf-8", "surrogateescape"))
            slot = self.headers["X-Coworld-Player-Slot"]
            seat = int(slot)
            assert (
                seat in range(3) and body["model"] == "local/factory-commons-sentinel"
            )
            assert body["max_tokens"] == 700
            user = body["messages"][0]["content"]
            assert "native fixture only" in user
            shift = int(re.search(r"SHIFT (\d+)", user).group(1))
            for other in range(3):
                if other != seat:
                    assert f"PRIVATE_SLOT_{other}_" not in user
            job = "maintain" if shift >= 3 and shift % 3 == seat else "operate"
            order = {
                "job": job,
                "cube": "pink" if seat % 2 == 0 else "blue",
                "say": f"slot {seat} {job}",
                "notes": f"PRIVATE_SLOT_{seat}_SHIFT_{shift}",
            }
            if args.mode == "external" and seat == 0 and shift >= 4:
                order["job"] = (
                    "strip"  # Valid installed order despite cycle-lock primitive rules.
                )
            text = json.dumps(order, separators=(",", ":"))
            status = 400 if raw is None else 200
            retry = "Your previous reply was invalid" in user
            if args.mode == "retry" and not retry:
                text = "deliberately malformed local response"
            if args.mode == "throttle" and shift == 1:
                status = 429
            if args.mode == "auth":
                status = 403
            fixture_case = "ordinary-positive"
            if args.mode == "mixed":
                ordinary_cases = [
                    ("supported-fence", '```json\n{"job":"operate"}\n```'),
                    ("case-normalization", '{"job":" OPERATE ","cube":"any"}'),
                    ("null-default", '{"job":"maintain","cube":null}'),
                    ("unknown-key", '{"job":"operate","ignored":1}'),
                    ("duplicate-key", '{"job":"operate","job":"operate"}'),
                    ("nonfinite-extra", '{"job":"maintain","extra":1e999}'),
                    ("newline-normalization", '{"job":"operate","say":"a\\nb"}'),
                    (
                        "rune-truncation",
                        '{"job":"maintain","notes":"' + "x" * 321 + '"}',
                    ),
                    ("wrong-type-default", '{"job":"operate","say":false}'),
                    ("trailing-comma", '{"job":"maintain",}'),
                    ("comment", '{"job":"maintain"/*comment*/}'),
                    (
                        "depth-bound",
                        '{"job":"maintain","extra":' + "[" * 34 + "0" + "]" * 34 + "}",
                    ),
                ]
                if shift <= 4:
                    fixture_case, text = ordinary_cases[(shift - 1) * 3 + seat]
                elif shift == 5:
                    fixture_case, text = [
                        ("escaped-low-notes", '{"job":"operate","notes":"\\uDC00"}'),
                        (
                            "raw-low-notes",
                            '{"job":"operate","notes":"RAW_LOW_SURROGATE"}',
                        ),
                        (
                            "raw-invalid-notes",
                            '{"job":"operate","notes":"RAW_INVALID_BYTE"}',
                        ),
                    ][seat]
                elif shift == 6:
                    fixture_case = "request-after-unicode-rejection"
                    assert raw is not None, "invalid notebook escaped native rejection"
                    json.dumps(body, ensure_ascii=False).encode("utf-8")
                elif shift == 7:
                    fixture_case, text = [
                        ("escaped-low-key", '{"job":"operate","\\uDC00":"ignored"}'),
                        (
                            "raw-low-key",
                            '{"job":"operate","RAW_LOW_SURROGATE":"ignored"}',
                        ),
                        (
                            "raw-invalid-key",
                            '{"job":"operate","RAW_INVALID_BYTE":"ignored"}',
                        ),
                    ][seat]
                elif shift == 8 and seat == 0:
                    fixture_case = "valid-unicode-scalar"
                    text = '{"job":"maintain","notes":"🍌"}'
                if shift == 1 and seat == 0 and not retry:
                    time.sleep(20.2)
            response = {
                "id": "local-message",
                "model": body["model"],
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": {"input_tokens": 17, "output_tokens": 11},
            }
            if status != 200:
                response = {"error": {"message": "local fixture refusal"}}
            encoded = json.dumps(response).encode()
            if args.mode == "mixed" and status == 200:
                encoded = encoded.replace(
                    b"RAW_LOW_SURROGATE", b"\xed\xb0\x80"
                ).replace(b"RAW_INVALID_BYTE", b"\x80")
            try:
                response_text = encoded.decode("utf-8")
            except UnicodeDecodeError:
                response_text = None
            call = str(uuid.uuid4())
            entry = {
                "call_id": call,
                "fixture_case": fixture_case,
                "slot": slot,
                "shift": shift,
                "retry": retry,
                "request_body": raw,
                "request_body_b64": base64.b64encode(raw_bytes).decode(),
                "response_body": response_text,
                "response_body_b64": base64.b64encode(encoded).decode(),
                "status": status,
                "elapsed_seconds": time.monotonic() - started,
                "request_received_seconds": received_seconds,
            }
            with call_lock:
                assert len(calls) < 90
                calls.append(entry)
                with (output / "http-calls.jsonl").open("a") as handle:
                    handle.write(json.dumps(entry) + "\n")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("X-Softmax-Llm-Call-Id", call)
            self.send_header("request-id", "local-request-" + call)
            self.send_header("Set-Cookie", "DO_NOT_CAPTURE_SECRET_COOKIE")
            self.end_headers()
            try:
                self.wfile.write(encoded)
            except BrokenPipeError:
                pass  # The one declared native timeout retains its fixture-side evidence.

    try:
        fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        manifest = json.loads(Path("coworld_manifest_template.json").read_text())
        config = dict(
            next(
                v["game_config"]
                for v in manifest["variants"]
                if v["id"] == args.variant
            )
        )
        config.update(tokens=[f"local-token-{s}" for s in range(3)], seed=1)
        (output / "config.json").write_text(json.dumps(config, indent=2) + "\n")
        port = free_port()
        clean = {
            k: os.environ[k]
            for k in ("PATH", "HOME", "TMPDIR", "LANG")
            if k in os.environ
        }
        env = clean | {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
            "COWORLD_LLM_MODEL": "local/factory-commons-sentinel",
            "COWORLD_EPISODE_ID": "local-native-fixture",
            "COWORLD_GAME_VERSION": "local-fixture",
            "COWORLD_SOURCE_REVISION": "local-source-sha256:" + source_hash,
        }
        if not args.no_capture:
            env["COGAME_SAVE_TRAJECTORY_URI"] = (
                f"http://127.0.0.1:{fixture.server_port}/private-trajectory"
                if args.mode == "publication"
                else (output / "trajectory.jsonl").as_uri()
            )
        audit = []

        def launch(binary, child_env, role):
            assert not any(
                k.startswith(("AWS_", "ANTHROPIC_", "OPENAI_", "BEDROCK_"))
                for k in child_env
            )
            audit.append(
                {
                    "role": role,
                    "binary": str(binary.resolve()),
                    "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                    "child_env_keys": sorted(child_env),
                    "routing": "explicit loopback fixture only",
                }
            )
            (output / "environment-audit.json").write_text(
                json.dumps(audit, indent=2) + "\n"
            )
            log = (output / f"{role}.log").open("w")
            logs.append(log)
            process = subprocess.Popen(
                [str(binary.resolve())],
                env=child_env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(process)
            return process

        game = launch(args.game, env, "game")
        ready_by = time.monotonic() + 20
        while True:
            measure(output, processes, calls, started)
            assert game.poll() is None, "game exited before HTTP health"
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ) as response:
                    assert response.status == 200
                    break
            except OSError:
                assert time.monotonic() < ready_by, "HTTP health deadline"
                time.sleep(0.1)
        viewer = threading.Thread(
            target=observe_globals, args=(port, output, stop, failures), daemon=True
        )
        viewer.start()
        if args.mode == "publication":
            # The pinned Mummy emits `HTTP/1.1 401` without the final status-line
            # space/reason phrase. Preserve that existing protocol gap while
            # proving refusal, rather than requiring a specific client exception.
            key = base64.b64encode(os.urandom(16)).decode()
            request = (
                f"GET /player?slot=0&token=wrong-fixture-token HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{port}\r\nConnection: Upgrade\r\n"
                f"Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
                f"Sec-WebSocket-Key: {key}\r\n\r\n"
            ).encode()
            with socket.create_connection(("127.0.0.1", port), timeout=2) as refused:
                refused.sendall(request)
                response = b""
                while b"\r\n\r\n" not in response:
                    chunk = refused.recv(4097 - len(response))
                    assert chunk, "bad-token refusal ended before HTTP headers"
                    response += chunk
                    assert len(response) <= 4096, "bad-token response 4 KiB bound"
            status_line = response.split(b"\r\n", 1)[0]
            assert status_line.startswith(b"HTTP/1.1 401")
            assert not status_line.startswith(b"HTTP/1.1 101")
            (output / "bad-player-token-response.bin").write_bytes(response)
            (output / "bad-player-token-proof.json").write_text(
                json.dumps(
                    {
                        "status": 401,
                        "joined": False,
                        "upgrade_101": False,
                        "response_bytes": len(response),
                        "status_line_b64": base64.b64encode(status_line).decode(),
                        "existing_status_line_gap": status_line == b"HTTP/1.1 401",
                        "valid_client_viewer_Pong_checks_unchanged": True,
                    },
                    indent=2,
                )
                + "\n"
            )
        external = None
        for seat in range(3):
            if args.mode == "external" and seat == 1:
                external = threading.Thread(
                    target=external_player,
                    args=(port, output, stop, failures),
                    daemon=True,
                )
                external.start()
                continue
            player_env = clean | {
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=local-token-{seat}"
            }
            if (
                args.mode in {"retry", "throttle", "auth", "publication", "external"}
                and seat > 0
            ):
                player_env["PLAYER_SCRIPTED"] = "steward"
            else:
                player_env["PLAYER_PROMPT"] = "native fixture only"
            launch(args.player, player_env, f"player-{seat}")
        while game.poll() is None:
            measure(output, processes, calls, started)
            time.sleep(1)
        assert game.returncode == 0
        stop.set()
        viewer.join(timeout=5)
        for player in processes[1:]:
            assert player.wait(timeout=5) == 0
        results = json.loads((output / "results.json").read_text())
        # Invalid response bytes remain forensic evidence, never a standing order,
        # next native request or public replay string.
        for call in calls:
            request = json.loads(
                base64.b64decode(call["request_body_b64"]).decode("utf-8")
            )
            json.dumps(request, ensure_ascii=False).encode("utf-8")
        summary["native_requests_scalar_utf8"] = True
        replay_bytes = (output / "replay.json").read_bytes()
        replay = json.loads(replay_bytes.decode("utf-8"))
        json.dumps(replay, ensure_ascii=False).encode("utf-8")
        summary["public_replay_scalar_utf8"] = True
        assert results["reason"] == "complete" and results["shifts"] == 15
        assert len(replay["frames"]) == 900
        assert calls
        assert not failures, f"native viewer regression: {failures}"
        if args.mode == "publication":
            assert (
                "private capture publication failed"
                in (output / "game.log").read_text()
            )
            summary["private_publication_expected_failure"] = True
            summary["admitted_teacher_targets"] = 0
        trajectory = output / "trajectory.jsonl"
        if args.no_capture:
            assert not trajectory.exists()
        else:
            assert trajectory.is_file(), (
                "full native game omitted requested private model trajectory"
            )
        evidence = (
            check_evidence(output, calls, args.mode) if trajectory.exists() else None
        )
        summary.update(
            status="passed",
            results=results,
            ticks=900,
            calls=len(calls),
            private_capture_exists=trajectory.exists(),
            evidence=evidence,
        )
    except BaseException as error:
        summary["failure"] = repr(error)
        raise
    finally:
        stop.set()
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        if viewer:
            viewer.join(timeout=5)
        if fixture:
            fixture.shutdown()
        for log in logs:
            log.close()
        summary["elapsed_seconds"] = time.monotonic() - started
        summary["viewer_failures"] = failures
        (output / "result-card.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary))


if __name__ == "__main__":
    main()
