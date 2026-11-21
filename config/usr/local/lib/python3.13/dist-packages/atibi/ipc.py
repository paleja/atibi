"""cliamp IPC version 2: newline-delimited JSON over the daemon's Unix socket,
the same protocol `cliamp remote` speaks.

The envelope shapes are not a style choice. Verified against cliamp 2.4.1 on the
card: only operation.submit carries its operation name on the envelope, beside
method rather than inside params, and job.get carries job_id the same way; nest
either one and the daemon answers invalid_request / invalid_params.
"""

import json
import socket
import threading
import time


class IpcError(Exception):
    """What the daemon said, in its words. On this box those words are facts:
    "sign-in required" means the DHCP lease had not landed yet, and a TLS
    failure means the cold-boot clock is behind NTP."""


class Ipc:
    """One connection per request, serialized under one lock: the requests are
    tiny, and ordering them is cheaper than reconnect logic."""

    def __init__(self, sock_path, timeout=5.0, sleep=time.sleep,
                 job_tries=240, job_delay=0.5):
        self.sock_path = sock_path
        self.timeout = timeout
        self.sleep = sleep
        self.job_tries = job_tries
        self.job_delay = job_delay
        self._lock = threading.Lock()

    def request(self, method, params=None, envelope=None, id_hint="h"):
        """One request/reply pair. A reply with another id is a stray frame,
        not an answer: subscribe pushes events, and reading one as the answer
        would misreport the player's state to the person driving it."""
        body = {"version": 2, "id": id_hint, "method": method}
        if envelope:
            body.update(envelope)
        if params is not None:
            body["params"] = params
        with self._lock:
            handle = None
            try:
                handle = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                handle.settimeout(self.timeout)
                handle.connect(self.sock_path)
                stream = handle.makefile("rwb")
                stream.write((json.dumps(body) + "\n").encode())
                stream.flush()
                while True:
                    raw = stream.readline()
                    if not raw:
                        raise IpcError("the player closed the connection")
                    reply = json.loads(raw)
                    if reply.get("id") == id_hint:
                        return reply
            except (OSError, ValueError) as exc:
                raise IpcError(str(exc)) from exc
            finally:
                if handle is not None:
                    try:
                        handle.close()
                    except OSError:
                        pass

    def op(self, operation, params=None):
        """One operation, waited the way `cliamp remote call --wait` does. Slow
        is fine - loading a 50-track list from the service is exactly the case -
        and a silent failure is not, so a job that ends failed or canceled
        raises with its detail rather than returning nothing."""
        reply = self.request("operation.submit", params, id_hint="h",
                             envelope={"operation": operation})
        if not reply.get("ok"):
            raise IpcError(reply.get("error", "%s refused" % operation))
        job = reply.get("job", {})
        tries = 0
        while job.get("state") not in ("succeeded", "failed", "canceled"):
            tries += 1
            if tries > self.job_tries or not job.get("id"):
                raise IpcError("%s did not finish in time" % operation)
            answer = self.request("job.get", id_hint="h.job%d" % tries,
                                 envelope={"job_id": job["id"]})
            if not answer.get("ok"):
                raise IpcError(answer.get("error", "job vanished"))
            job = answer.get("job", job)
            if job.get("state") not in ("succeeded", "failed", "canceled"):
                self.sleep(self.job_delay)
        if job.get("state") != "succeeded":
            detail = job.get("result", {}).get("detail") or job["state"]
            raise IpcError("%s: %s" % (operation, detail))
        return job.get("result", {})

    def snapshot(self):
        """The player's whole state: the row it is on, the label of the list it
        came from, the transport. 20 keys on cliamp 2.4.1, and no level among
        them: the level is not reachable over IPC (see player.level)."""
        return self.request("state.get").get("snapshot") or {}
