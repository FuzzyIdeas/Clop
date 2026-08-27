#!/usr/bin/env python3
"""Clop MCP server.

A stdio Model Context Protocol server that lets any MCP-capable LLM drive Clop:
optimise, downscale, convert and crop images, videos, PDFs and audio, run and
author pipelines, attach them to watched folders and drop zone presets, and read
or change any Clop setting in plain language.

There is no HTTP server involved. Clop already answers a CFMessagePort, and the
bundled `ClopCLI` binary already speaks it with `--json`, so this file shells out
to that binary and hands the JSON back. Every call carries `CLOP_ORIGIN=mcp`,
which is what lets Clop check for Clop Pro and refuse changes until the user has
switched agents on.

Dependency-free (Python 3 stdlib). Newline-delimited JSON-RPC 2.0 on
stdin/stdout; all logging goes to stderr so it never corrupts the stream.

Register with:  claude mcp add clop -- python3 /path/to/clop_mcp.py
"""
import base64
import hashlib
import hmac
import itertools
import json
import os
import select
import re
import secrets
import subprocess
import sys
import time

SERVER_NAME = "clop-mcp"
SERVER_VERSION = "1.0.0"

# Only the fallback for a client that omits the field. The negotiated version is
# whatever the client asked for, since `initialize` echoes it back, so anything
# version-dependent branches on STATE.protocol rather than on this.
DEFAULT_PROTOCOL = "2025-11-25"

# 2026-07-28 replaced server-initiated requests with Multi Round-Trip Requests and
# called it a breaking change, so elicitation splits on this version. The versions
# sort lexicographically, which is why a plain string compare is enough.
MRTR_FROM = "2026-07-28"

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_CARD = os.path.expanduser("~/.well-known/mcp/clop.json")

BUY_URL = "https://lowtechguys.com/clop"

# A person has to answer the dialog, so this is a person's wait, not a process's.
ELICIT_TIMEOUT = float(os.environ.get("CLOP_MCP_ELICIT_TIMEOUT", "120"))

# A pipeline over a folder of videos is minutes of ffmpeg, so file work gets its
# own timeout rather than the 30s that suits a settings read.
FILE_TIMEOUT = 900


def log(*a):
    print("[clop-mcp]", *a, file=sys.stderr, flush=True)


class ClopError(Exception):
    pass


# ----- Finding the CLI ---------------------------------------------------------

def _card():
    """The discovery card Clop writes on every launch. A hint, never a requirement."""
    try:
        with open(SERVER_CARD) as f:
            return json.load(f)
    except Exception:
        return {}


def cli_path():
    """The ClopCLI binary. The bundled copy beside this script wins.

    With more than one Clop around (a debug build in /tmp next to /Applications),
    the copy that shipped this script is the one whose port answers first, and it
    is the one the user meant.
    """
    if os.environ.get("CLOP_CLI"):
        return os.environ["CLOP_CLI"]
    # Contents/Resources/clop_mcp.py -> Contents/SharedSupport/ClopCLI
    bundled = os.path.normpath(os.path.join(HERE, "..", "SharedSupport", "ClopCLI"))
    if os.access(bundled, os.X_OK):
        return bundled
    app = (_card().get("app") or {}).get("path")
    if app:
        inside = os.path.join(app, "Contents/SharedSupport/ClopCLI")
        if os.access(inside, os.X_OK):
            return inside
    local = os.path.expanduser("~/.local/bin/clop")
    if os.access(local, os.X_OK):
        return local
    raise ClopError("cannot find the Clop CLI. Is Clop installed?")


# Clop's own refusals are the words the agent should read, so they come back
# verbatim. Only the next step is added, and it is always "ask the user", never
# anything about quitting or reopening Clop: MCP is Pro so relaunching buys an
# agent nothing on this path, but the same words would teach the trick for the
# CLI and Shortcuts paths, whose free counters do reset on relaunch by design.
def _next_step(message):
    low = message.lower()
    if "clop pro" in low:
        # Clop already said which licence it wants, so only the next step is added.
        return " The user can buy a licence at " + BUY_URL + "."
    # A whole word, not a substring: "process", "provide" and "property" all contain "pro", and each
    # of them used to get a licence pitch bolted onto an unrelated error.
    if re.search(r"\bpro\b", low):
        return " Clop's MCP server needs Clop Pro. The user can buy a licence at " + BUY_URL + "."
    if "script" in low and "allow" in low:
        return (" Script steps are behind their own switch. Ask the user to allow them in "
                "Clop Settings, MCP. Prefer a built-in step: it is faster, the editor understands "
                "it, and it survives a Clop update.")
    if "not accepting changes" in low or "agents" in low:
        return (" Ask the user to allow agent changes in Clop Settings, MCP, or call "
                "clop_start_server, which puts that question on screen for them.")
    return ""


def run(args, timeout=30, want_json=True):
    """Run one Clop CLI command and return its parsed JSON response."""
    argv = [cli_path()] + [str(a) for a in args]
    if want_json:
        argv.append("--json")
    env = dict(os.environ, CLOP_ORIGIN="mcp")
    try:
        proc = subprocess.run(argv, capture_output=True, timeout=timeout, env=env)
    except FileNotFoundError:
        raise ClopError("cannot run the Clop CLI. Is Clop installed?")
    except subprocess.TimeoutExpired:
        raise ClopError(f"Clop did not answer within {timeout}s")

    # Never `text=True`: a file name can carry bytes that are not UTF-8, and a
    # decode error here would surface as a tool crash instead of a result.
    out = proc.stdout.decode(errors="replace").strip()
    err = proc.stderr.decode(errors="replace").strip()
    if not want_json:
        if proc.returncode != 0:
            raise ClopError(_annotate(err or out or f"Clop exited {proc.returncode}"))
        return {"output": out}
    if not out:
        raise ClopError(_annotate(err or f"Clop exited {proc.returncode} with no output"))
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        if proc.returncode != 0:
            raise ClopError(_annotate(err or out))
        # A command that forgot `--json` still reads, rather than failing the call.
        return {"output": out}
    if parsed.get("ok") is False:
        raise ClopError(_annotate(parsed.get("error") or err or "Clop refused the request"))

    # A file command reports per-file outcomes in done[] and failed[] and still exits 0, so a licence
    # refusal or a gate refusal used to arrive as a SUCCESSFUL tool result carrying a bare internal
    # string. The agent was told nothing it could act on and had no reason to think anything went
    # wrong. Every failure message gets the same next step a top-level error would, and a call where
    # nothing succeeded is an error.
    failed = parsed.get("failed") or []
    if failed:
        for item in failed:
            if isinstance(item, dict) and item.get("error"):
                item["error"] = _annotate(item["error"])
        if not (parsed.get("done") or []):
            raise ClopError("; ".join(
                item["error"] for item in failed
                if isinstance(item, dict) and item.get("error")
            ) or "Clop could not process any of the files")
    return _prune(parsed)


def _annotate(message):
    return message + _next_step(message)


def text(args, timeout=30):
    """Run a command whose output is prose, not JSON (pipeline prompt, strip-exif)."""
    return run(args, timeout=timeout, want_json=False)


def note(body):
    """A plain-text tool result. Same sentinel shape `text()` returns."""
    return {"output": body}


def _prune(obj):
    """Drop the nulls the Swift encoder leaves behind, so a tool result reads."""
    if isinstance(obj, dict):
        return {k: _prune(v) for k, v in obj.items() if v is not None}
    if isinstance(obj, list):
        return [_prune(v) for v in obj]
    return obj


def _opt(args, flag, key=None):
    value = args.get(key or flag.lstrip("-"))
    return [flag, str(value)] if value not in (None, "") else []


def _flag(args, key, flag):
    return [flag] if args.get(key) else []


def _paths(args, key="paths"):
    """The files a tool works on, expanded but not resolved.

    Left as the user wrote them beyond `~`, since Clop reports results keyed by
    the input URL and a resolved path would stop matching what the agent asked for.
    """
    paths = args.get(key)
    if isinstance(paths, str):
        paths = [paths]
    paths = [os.path.expanduser(str(p)) for p in (paths or []) if str(p).strip()]
    if not paths:
        raise ClopError("no files given: pass one or more paths, folders or URLs")
    return paths


def _subject(paths):
    first = os.path.basename(paths[0].rstrip("/")) or paths[0]
    if len(paths) == 1:
        return first
    return "%s and %d more" % (first, len(paths) - 1)


# ----- The switch --------------------------------------------------------------

def _open_args(url):
    """Route the URL to the Clop that wrote the server card.

    With more than one copy around (a debug build next to /Applications), plain
    `open` picks whichever LaunchServices prefers, which may not be the one whose
    MCP server this is. The card names its own app, so aim at that.
    """
    app = (_card().get("app") or {}).get("path")
    if app and os.path.exists(app):
        return ["/usr/bin/open", "-a", app, url]
    return ["/usr/bin/open", url]


def start_server(wait=90.0):
    """Ask Clop to allow changes through MCP, launching it if it is not running.

    Opening the URL is what makes this work while nothing is listening: macOS
    hands `clop://` to the app and launches it first if needed. Clop then shows an
    alert and waits for a person, so the wait here is a person's wait.
    """
    try:
        subprocess.run(_open_args("clop://mcp/start"), check=True, capture_output=True, timeout=15)
    except FileNotFoundError:
        raise ClopError("could not run /usr/bin/open")
    except subprocess.CalledProcessError as e:
        raise ClopError(f"could not reach Clop: {e.stderr.decode(errors='replace').strip() or 'is Clop installed?'}")

    deadline = time.time() + wait
    while time.time() < deadline:
        try:
            state = run(["mcp", "status"])
            if (state.get("mcp") or {}).get("enabled"):
                return state
        except ClopError:
            # Clop may still be launching, so every round swallows the error and
            # asks again rather than giving up on the first one.
            pass
        time.sleep(0.4)

    # The card is rewritten when Clop handles the URL, so re-reading it after the
    # wait tells a licence refusal apart from an unanswered dialog.
    if _card().get("pro") is False:
        raise ClopError("Clop's MCP server needs Clop Pro. Nothing changed. "
                        "The user can buy a licence at " + BUY_URL + ".")
    raise ClopError("Clop asked and the answer did not come (or it was no). Nothing changed. "
                    "Ask the user to allow it in Clop Settings, MCP.")


def stop_server():
    # Taking permission away needs no alert, so this never waits and never checks.
    subprocess.run(_open_args("clop://mcp/stop"), check=False, capture_output=True, timeout=15)
    return {"ok": True, "stopped": True,
            "note": "Clop will refuse changes from agents until it is started again. Reading still works."}


def status():
    state = run(["mcp", "status"])
    card = _card()
    for key in ("version", "displayName", "description"):
        if card.get(key) is not None:
            state.setdefault(key, card[key])
    return state


# ----- Elicitation -------------------------------------------------------------
# Clop asks the user only for real ambiguity, and there are exactly two cases:
# "make it smaller" is compression or resolution or both, and a size or quality
# with no number in it. A tool that already knows what to do never stops to ask.

class State:
    protocol = DEFAULT_PROTOCOL
    modes = set()          # elicitation modes the client declared
    client_name = ""


STATE = State()


def elicitation_modes(caps):
    """Modes the client declared. An empty object means form only."""
    el = (caps or {}).get("elicitation")
    if el is None:
        return set()
    if not el:
        return {"form"}
    return {m for m in ("form", "url") if m in el}


def uses_mrtr():
    return STATE.protocol >= MRTR_FROM


class Declined(Exception):
    """The user said no."""


class Cancelled(Exception):
    """The dialog was dismissed, or nobody answered in time."""


class NoElicitation(Exception):
    """The client cannot ask, so the agent asks in its own chat instead."""


class NeedInput(Exception):
    """MRTR: the tool call returns, and the client calls again with the answers."""

    def __init__(self, key, message, schema):
        super().__init__(key)
        self.key = key
        self.message = message
        self.schema = schema


# --- a line reader with a deadline

class LineReader:
    """Byte-level line reader over stdin, with an optional deadline.

    `for line in sys.stdin` cannot be given a deadline, and `readline()` on a pipe
    can block after `select` says readable when only part of a line arrived. So the
    bytes are read from the raw fd and split here.

    Decoding is lenient for the reason rcmd's `sys.stdin.reconfigure` exists: a byte
    that is not UTF-8 would otherwise raise out of the loop itself, below every
    `try`, and kill the server on one malformed line.
    """

    def __init__(self, fd=0):
        self.fd = fd
        self.buf = b""
        self.eof = False

    def next_line(self, deadline=None):
        """Bytes without the newline, or None on timeout. Raises EOFError at EOF."""
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line, self.buf = self.buf[:nl], self.buf[nl + 1:]
                return line
            if self.eof:
                if self.buf:
                    line, self.buf = self.buf, b""
                    return line
                raise EOFError("client closed stdin")
            timeout = None
            if deadline is not None:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    return None
            r, _, _ = select.select([self.fd], [], [], timeout)
            if not r:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                self.eof = True
                continue
            self.buf += chunk


READER = LineReader()


def parse(line):
    try:
        return json.loads(line.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        return None


# --- the pump

# Server-initiated ids are strings with a `clop-` prefix so they can never collide
# with the client's own integer ids, which is what makes dispatch by id safe.
_elicit_ids = itertools.count(1)
PENDING = {}       # our request id -> None, then the raw response message
OWNER = {}         # our request id -> the client tools/call id it serves


class Depth:
    value = 0


DEPTH = Depth()


def next_elicit_id():
    return "clop-elicit-%d" % next(_elicit_ids)


def elicit(message, requested_schema, timeout=ELICIT_TIMEOUT):
    """Ask the user one question mid-call, servicing the client while we wait.

    The loop below answers anything else the client sends while the dialog is up:
    another tools/call, a ping, tools/list, a cancellation. Blocking on a read of
    one id instead would deadlock a client that pipelines requests.
    """
    if "form" not in STATE.modes:
        raise NoElicitation()
    if DEPTH.value > 1:
        # One level of nesting is fine. Deeper loses track of which dialog belongs
        # to which call, and can leave one on screen after its tool has returned.
        raise NoElicitation()

    rid = next_elicit_id()
    PENDING[rid] = None
    OWNER[rid] = CURRENT.request_id
    send({"jsonrpc": "2.0", "id": rid, "method": "elicitation/create",
          "params": {"mode": "form", "message": message, "requestedSchema": requested_schema}})

    deadline = time.monotonic() + timeout
    try:
        while PENDING[rid] is None:
            try:
                line = READER.next_line(deadline)
            except EOFError:
                raise SystemExit(0)      # the client is gone, nothing to reply to
            if line is None:
                # Never block forever: the client's own tool timeout would fire
                # first and leave a dialog on screen with no result behind it.
                send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                      "params": {"requestId": rid, "reason": "no answer within %gs" % timeout}})
                raise Cancelled("timeout")
            line = line.strip()
            if not line:
                continue
            msg = parse(line)
            if msg is None:
                continue
            try:
                dispatch(msg)
            except SystemExit:
                raise
            except Exception as e:
                log("nested handler crashed:", e)
        return interpret(PENDING[rid])
    finally:
        PENDING.pop(rid, None)
        OWNER.pop(rid, None)


def interpret(msg):
    if "error" in msg:
        # -32602 means we sent a mode the client did not declare, -32601 means it
        # declared the capability and does not route the method. Either way, fall
        # back to text rather than failing the tool.
        log("elicitation error:", msg["error"])
        raise NoElicitation()
    result = msg.get("result") or {}
    action = result.get("action")
    if action == "accept":
        return result.get("content") or {}
    if action == "decline":
        raise Declined()
    # Anything that is not exactly accept or decline is read as a dismissal, which
    # is the safe reading of a shape we did not expect.
    raise Cancelled(action or "cancel")


def on_cancelled(params):
    """The client gave up on the outer tools/call, so let the handler unwind."""
    req = (params or {}).get("requestId")
    for rid, owner in list(OWNER.items()):
        if owner == req and PENDING.get(rid) is None:
            PENDING[rid] = {"id": rid, "result": {"action": "cancel"}}


def as_int(content, key, default=None):
    """Clients are allowed to hand back a string where the schema said a number."""
    value = content.get(key, default)
    try:
        return int(str(value).strip().rstrip("%"))
    except (TypeError, ValueError):
        return default


def as_float(content, key, default=None):
    value = content.get(key, default)
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return default


# --- MRTR state, for the day a stdio client negotiates 2026-07-28
# The server keeps nothing between the two calls: everything needed to resume goes
# into `requestState`, which the spec says to treat as attacker-controlled. So it
# is signed with a per-process key, carries a TTL and names the tool and the
# arguments it was issued for. A restarted server rejecting old state is correct
# behaviour rather than a bug.

_STATE_KEY = secrets.token_bytes(32)
_STATE_TTL = 300.0


def _args_digest(args):
    return hashlib.sha256(json.dumps(args, sort_keys=True, default=str).encode()).hexdigest()


def seal_state(tool, args):
    raw = json.dumps({"tool": tool, "args": _args_digest(args), "at": time.time()},
                     sort_keys=True).encode()
    tag = hmac.new(_STATE_KEY, raw, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(raw).decode() + "." + base64.urlsafe_b64encode(tag).decode()


def open_state(blob, tool, args):
    try:
        raw_b64, tag_b64 = str(blob).split(".", 1)
        raw = base64.urlsafe_b64decode(raw_b64)
        tag = base64.urlsafe_b64decode(tag_b64)
    except Exception:
        raise ClopError("requestState is not readable, so the answers were dropped. Call the tool again.")
    if not hmac.compare_digest(tag, hmac.new(_STATE_KEY, raw, hashlib.sha256).digest()):
        raise ClopError("requestState failed its integrity check, so the answers were dropped.")
    payload = json.loads(raw.decode())
    if payload.get("tool") != tool or payload.get("args") != _args_digest(args):
        raise ClopError("requestState belongs to a different call, so the answers were dropped.")
    if time.time() - float(payload.get("at") or 0) > _STATE_TTL:
        raise ClopError("requestState expired. Call the tool again.")
    return payload


# --- one entry point the tool bodies use, whichever path is live

class Call:
    """The tools/call being served. Single-threaded, so one module global is enough."""

    def __init__(self):
        self.request_id = None
        self.name = None
        self.args = {}
        self.params = {}


CURRENT = Call()


def refuse_before_asking():
    """Raise if a file operation is going to be refused anyway.

    Elicitation costs the USER something: a dialog, or a question in the chat. Asking which way they
    want a file made smaller and then answering "needs Clop Pro" spends their attention on a decision
    that was never going to be acted on. This is checked only before a question, not on every call:
    the ordinary path already surfaces Clop's own refusal, and a status check per tool call would mean
    spawning a process to say what the next process is about to say.
    """
    try:
        state = (run(["mcp", "status"]).get("mcp") or {})
    except ClopError:
        return  # If status cannot be read, let the real call produce the real error.
    if not state.get("pro"):
        raise ClopError(_annotate("Clop's MCP server needs Clop Pro."))
    if not state.get("enabled"):
        raise ClopError(_annotate(
            "Clop is not accepting changes from agents. Ask the user to allow it in Clop Settings, MCP."
        ))


def ask(key, message, schema):
    """Answers for `key`, however this client can give them.

    Raises Declined, Cancelled or NoElicitation on the pump path, and NeedInput on
    the MRTR path, so a tool body is written once and neither path leaks into it.
    """
    if uses_mrtr():
        responses = (CURRENT.params.get("inputResponses") or {})
        if key in responses:
            open_state(CURRENT.params.get("requestState"), CURRENT.name, CURRENT.args)
            answer = responses[key] or {}
            action = answer.get("action")
            if action == "accept":
                return answer.get("content") or {}
            if action == "decline":
                raise Declined()
            raise Cancelled(action or "cancel")
        if "form" not in _mrtr_modes():
            raise NoElicitation()
        raise NeedInput(key, message, schema)
    return elicit(message, schema)


def _mrtr_modes():
    """2026-07-28 moved capabilities into each request's `_meta`."""
    meta = (CURRENT.params.get("_meta") or {})
    caps = meta.get("io.modelcontextprotocol/clientCapabilities") or {}
    return elicitation_modes(caps)


SMALLER_SCHEMA = {
    "type": "object",
    "properties": {
        "target": {
            "type": "string",
            "title": "Make smaller by",
            "description": "Compression keeps the pixel size, resolution keeps the quality",
            "oneOf": [
                {"const": "compression", "title": "Compressing it"},
                {"const": "resolution", "title": "Reducing the resolution"},
                {"const": "both", "title": "Both"},
            ],
            "default": "compression",
        },
        "quality": {
            "type": "integer",
            "title": "Quality",
            "description": "Lower is smaller. 80 is the Clop default.",
            "minimum": 1,
            "maximum": 100,
            "default": 80,
        },
    },
    # `quality` stays out of `required` so someone who only picks a target is not
    # blocked on a number they have no opinion about.
    "required": ["target"],
}

SMALLER_OPTIONS_TEXT = (
    "Clop can make a file smaller in two ways, and the request did not say which.\n"
    "  compression: keeps the pixel size and lowers the quality. Pass smallerBy=compression, "
    "and quality as 5 to 100 (lower is smaller, 80 is Clop's default).\n"
    "  resolution: keeps the quality and shrinks the pixels. Pass smallerBy=resolution, "
    "and downscaleFactor as 0 to 1 (0.5 is half the width and height).\n"
    "  both: compress and downscale in one pass. Pass smallerBy=both.\n"
    "Ask the user which they want, then call clop_optimise again with that argument."
)

FACTOR_SCHEMA = {
    "type": "object",
    "properties": {
        "factor": {
            "type": "number",
            "title": "Downscale to",
            "description": "A fraction of the current size. 0.5 is half the width and height.",
            "minimum": 0.05,
            "maximum": 0.95,
            "default": 0.5,
        },
    },
    "required": ["factor"],
}

FACTOR_OPTIONS_TEXT = (
    "Downscaling needs a number and the request did not carry one. The factor is a fraction "
    "of the current size: 0.5 is half the width and height, 0.75 is a quarter off, 0.25 is a "
    "quarter of the size. For audio the same factor applies to the bitrate.\n"
    "Ask the user how much smaller they want it, then call clop_downscale again with factor."
)

# A client can answer a question without answering it: declined, cancelled, or dismissed because it
# had no way to show it at all. A non-interactive Claude Code session declares the elicitation
# capability and then cancels every request, so this is the common path and not the rare one.
#
# All three end the same way: say what happened in one line, then repeat the full options so the agent
# can ask in its own chat and call again. Anything shorter leaves it guessing at parameter names.
CANCELLED_PREFIX = (
    "The question was not answered. Some clients cannot show one at all, a non-interactive session "
    "for instance, so ask the user directly instead.\n"
)

DECLINED_PREFIX = "The user declined to answer, so ask them directly instead.\n"


# ----- File operations ---------------------------------------------------------
# `--async` is never passed: it returns before the work is done and prints no JSON
# body at all, so a result parsed from it would be a lie about what happened.

def _common_flags(a):
    return (_flag(a, "recursive", "--recursive")
            + _flag(a, "copy", "--copy")
            + _flag(a, "aggressive", "--aggressive")
            + _flag(a, "skipErrors", "--skip-errors")
            + _opt(a, "--output", "output")
            + _opt(a, "--types", "types")
            + _opt(a, "--behaviour", "behaviour"))


def clop_optimise(a):
    paths = _paths(a)
    smaller_by = a.get("smallerBy")
    quality = a.get("quality")
    factor = a.get("downscaleFactor")

    # The one genuinely ambiguous request. When the caller already said how, or
    # already gave a number, this asks nothing.
    if not smaller_by and quality is None and factor is None and not a.get("crop"):
        refuse_before_asking()
        try:
            content = ask("smaller_how",
                          "Clop can make %s smaller in two ways. Which should it use?" % _subject(paths),
                          SMALLER_SCHEMA)
        except Declined:
            return note(DECLINED_PREFIX + SMALLER_OPTIONS_TEXT)
        except Cancelled:
            return note(CANCELLED_PREFIX + SMALLER_OPTIONS_TEXT)
        except NoElicitation:
            return note(SMALLER_OPTIONS_TEXT)
        smaller_by = content.get("target") or "compression"
        quality = as_int(content, "quality", quality)

    argv = ["optimise", "files"] + paths + _common_flags(a)
    if smaller_by in (None, "compression", "both") and quality is not None:
        argv += ["--compression", str(quality)]
    elif a.get("compression"):
        argv += ["--compression", str(a["compression"])]
    if smaller_by in ("resolution", "both"):
        argv += ["--downscale-factor", str(factor or 0.5)]
    elif factor is not None:
        argv += ["--downscale-factor", str(factor)]
    argv += (_opt(a, "--crop", "crop")
             + _opt(a, "--pdf-dpi", "pdfDPI")
             + _opt(a, "--playback-speed-factor", "playbackSpeedFactor")
             + _flag(a, "removeAudio", "--remove-audio"))
    return run(argv, timeout=FILE_TIMEOUT)


def clop_downscale(a):
    paths = _paths(a)
    factor = a.get("factor")
    if factor is None:
        refuse_before_asking()
        try:
            content = ask("downscale_factor",
                          "How much smaller should Clop make %s?" % _subject(paths),
                          FACTOR_SCHEMA)
        except Declined:
            return note(DECLINED_PREFIX + FACTOR_OPTIONS_TEXT)
        except Cancelled:
            return note(CANCELLED_PREFIX + FACTOR_OPTIONS_TEXT)
        except NoElicitation:
            return note(FACTOR_OPTIONS_TEXT)
        factor = as_float(content, "factor", 0.5)

    return run(["downscale"] + paths + ["--factor", str(factor)]
               + _common_flags(a) + _flag(a, "removeAudio", "--remove-audio"),
               timeout=FILE_TIMEOUT)


def clop_convert(a):
    kind = a.get("kind")
    if kind not in ("image", "video", "audio"):
        raise ClopError("kind must be image, video or audio")
    return run(["convert", kind, "--to", a["to"]] + _paths(a)
               + _common_flags(a)
               + _opt(a, "--compression", "compression")
               + _opt(a, "--bitrate", "bitrate")
               + _opt(a, "--convert-behaviour", "convertBehaviour"),
               timeout=FILE_TIMEOUT)


def clop_crop(a):
    # The crop command spells `-s` as `--size`, so every flag here is written long
    # to keep it from meaning `--skip-errors` the way it does on optimise.
    return run(["crop"] + _paths(a) + ["--size", str(a["size"])]
               + _common_flags(a)
               + _flag(a, "longEdge", "--long-edge")
               + _flag(a, "smartCrop", "--smart-crop")
               + _flag(a, "removeAudio", "--remove-audio"),
               timeout=FILE_TIMEOUT)


def clop_strip_exif(a):
    return text(["strip-exif"] + _paths(a)
                + _flag(a, "recursive", "--recursive")
                + _opt(a, "--types", "types"),
                timeout=FILE_TIMEOUT)


def clop_crop_pdf(a):
    if not (a.get("forDevice") or a.get("paperSize") or a.get("aspectRatio")):
        raise ClopError("give one of forDevice, paperSize or aspectRatio")
    return text(["crop-pdf"] + _paths(a)
                + _opt(a, "--for-device", "forDevice")
                + _opt(a, "--paper-size", "paperSize")
                + _opt(a, "--aspect-ratio", "aspectRatio")
                + _opt(a, "--page-layout", "pageLayout")
                + _opt(a, "--output", "output")
                + _flag(a, "recursive", "--recursive")
                + _flag(a, "extend", "--extend"),
                timeout=FILE_TIMEOUT)


# ----- Pipelines ---------------------------------------------------------------
# Every one of these hands the pipeline to Clop rather than writing it here.
# Writing the steps from Python would go around the gate entirely: they would land
# while the switch reads "off", and Clop's own watcher would pick them up and run
# agent-authored steps anyway. Clop validates the name and the source path too,
# since `../../.zshrc` is a name an agent can ask for, and it is the Swift side
# that enforces mcpEnabled and mcpAllowScriptSteps.

def clop_pipeline_run(a):
    return run(["pipeline", "run", a["pipeline"]] + _paths(a)
               + _flag(a, "recursive", "--recursive")
               + _flag(a, "skipErrors", "--skip-errors")
               + _flag(a, "hideResult", "--hide-result")
               + _opt(a, "--types", "types")
               + _opt(a, "--optimise-behaviour", "optimiseBehaviour")
               + _opt(a, "--convert-behaviour", "convertBehaviour"),
               timeout=FILE_TIMEOUT)


def clop_pipeline_write(a):
    return text(["pipeline", "add", a["name"], a["steps"]]
                + _opt(a, "--file-type", "fileType")
                + _flag(a, "skipOptimisation", "--skip-optimisation")
                + _flag(a, "hideResult", "--hide-result")
                + _flag(a, "replace", "--force"),
                timeout=60)


def clop_pipeline_attach(a):
    return text(["pipeline", "attach", a["pipeline"], "--source", a["source"], "--type", a["type"]]
                + _flag(a, "skipOptimisation", "--skip-optimisation")
                + _flag(a, "hideResult", "--hide-result"),
                timeout=60)


def clop_pipeline_detach(a):
    if a.get("index") is not None and a.get("all"):
        raise ClopError("pass index or all, not both")
    return text(["pipeline", "detach", "--source", a["source"], "--type", a["type"]]
                + _opt(a, "--index", "index")
                + _flag(a, "all", "--all"),
                timeout=60)


def clop_pipeline_preset(a):
    action = a.get("action", "add")
    if action == "remove":
        return text(["pipeline", "preset", "remove", a["name"]] + _opt(a, "--type", "type"), timeout=60)
    if not a.get("pipeline"):
        raise ClopError("adding a preset zone needs a pipeline: a saved name or inline steps")
    return text(["pipeline", "preset", "add", a["name"], a["pipeline"]]
                + _opt(a, "--type", "type")
                + _opt(a, "--icon", "icon")
                + _flag(a, "skipOptimisation", "--skip-optimisation")
                + _flag(a, "hideResult", "--hide-result")
                + _flag(a, "replace", "--force"),
                timeout=60)


# ----- Tools -------------------------------------------------------------------

GATE = ("Refused until the user allows agent changes in Clop Settings, MCP, and the whole MCP "
        "server needs Clop Pro. Clop's own words come back verbatim when it refuses.")

TOOLS = [
    # --- the switch
    {
        "name": "clop_start_server",
        "description": ("Ask the user to allow changes through MCP, launching Clop if it is not running. "
                        "Clop puts an alert on screen and this waits for the answer, so call it once, in "
                        "response to something the user asked for, and tell them to expect it. Clop refuses "
                        "every mutating tool until they allow it; reading works either way once they have "
                        "Clop Pro, and the choice sticks across launches until it is stopped."),
        "inputSchema": {"type": "object", "properties": {}},
        "handler": lambda a: start_server(),
    },
    {
        "name": "clop_stop_server",
        "description": "Stop allowing changes through MCP. Reading stays available.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": lambda a: stop_server(),
    },
    {
        "name": "clop_status",
        "description": ("Clop's version, whether the user has Clop Pro, whether agent changes are allowed, "
                        "whether script steps are allowed, and where the server lives. Read this first when "
                        "a tool has been refused."),
        "inputSchema": {"type": "object", "properties": {}},
        "handler": lambda a: status(),
    },
    # --- settings
    {
        "name": "clop_settings_schema",
        "description": ("Every user-facing Clop setting: its key, current value, type, allowed values, and the "
                        "same title, subtitle and keywords the Settings window shows. Pass a plain-language "
                        "query to narrow it with Clop's own settings search, which is how a question like "
                        "'stop replacing the original' or 'why is the mov not becoming an mp4' finds the "
                        "control that answers it. Call this before clop_settings_set: the value a set takes is "
                        "the string form this shows, and a row with type 'none' hosts no key and can only be "
                        "pointed at."),
        "inputSchema": {"type": "object", "properties": {
            "query": {"type": "string", "description": "plain-language filter, e.g. 'replace the original', 'pdf quality'"}}},
        "handler": lambda a: run(["settings", "schema"] + ([a["query"]] if a.get("query") else [])),
    },
    {
        "name": "clop_settings_get",
        "description": "Read one setting by its key. Keys come from clop_settings_schema.",
        "inputSchema": {"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]},
        "handler": lambda a: run(["settings", "get", a["key"]]),
    },
    {
        "name": "clop_settings_set",
        "description": ("Change one setting. The value is the string form clop_settings_schema shows: true or "
                        "false for a bool, a number, or one of the allowed names for an enum. Applies "
                        "immediately and comes back carrying the new value, so no follow-up read is needed. "
                        + GATE),
        "inputSchema": {"type": "object", "properties": {
            "key": {"type": "string"}, "value": {"type": "string"}}, "required": ["key", "value"]},
        "handler": lambda a: run(["settings", "set", a["key"], a["value"]]),
    },
    # --- files
    {
        "name": "clop_optimise",
        "description": ("Optimise images, videos, PDFs and audio in place, or into a copy. Smaller files, same "
                        "pixels, unless a downscale is asked for. When the request is only 'make this smaller' "
                        "and carries no compression, factor or crop, Clop asks the user whether to compress, "
                        "downscale or do both, since those give very different files. Pass smallerBy, quality "
                        "or downscaleFactor to skip that question. Placement follows Clop's own setting, which "
                        "usually rewrites the original, so pass copy when the original must survive. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}, "description": "files, folders or URLs"},
            "smallerBy": {"type": "string", "description": "compression, resolution or both"},
            "quality": {"type": "integer", "description": "5 to 100, lower is smaller. 80 is Clop's default"},
            "compression": {"type": "string", "description": "5 to 100, or adaptive, or auto"},
            "downscaleFactor": {"type": "number", "description": "0 to 1, 0.5 is half the width and height"},
            "crop": {"type": "string", "description": "WxH, e.g. 1920x1080"},
            "pdfDPI": {"type": "string", "description": "adaptive, 300, 250, 200, 150, 100, 72 or 48"},
            "playbackSpeedFactor": {"type": "number", "description": "video only, 2 is twice as fast"},
            "removeAudio": {"type": "boolean", "description": "video only"},
            "aggressive": {"type": "boolean"},
            "copy": {"type": "boolean", "description": "keep the original and write a copy"},
            "recursive": {"type": "boolean", "description": "walk folders"},
            "types": {"type": "string", "description": "comma-separated extensions to include"},
            "output": {"type": "string", "description": "output path or template"},
            "behaviour": {"type": "string", "description": "temp, inplace, samefolder or specificfolder"},
            "skipErrors": {"type": "boolean"}},
            "required": ["paths"]},
        "handler": clop_optimise,
    },
    {
        "name": "clop_downscale",
        "description": ("Downscale and optimise images, videos and audio by a factor. For audio the factor "
                        "applies to the bitrate. When no factor is given Clop asks the user for one, since "
                        "'a bit smaller' is not a number. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}},
            "factor": {"type": "number", "description": "0 to 1, 0.5 is half the width and height"},
            "removeAudio": {"type": "boolean"},
            "aggressive": {"type": "boolean"},
            "copy": {"type": "boolean"},
            "recursive": {"type": "boolean"},
            "types": {"type": "string"},
            "output": {"type": "string"},
            "skipErrors": {"type": "boolean"}},
            "required": ["paths"]},
        "handler": clop_downscale,
    },
    {
        "name": "clop_convert",
        "description": ("Convert files to another format. Images take webp, avif, heic, jxl, jpeg or png; "
                        "videos take mp4, gif, webm, hevc or av1 (av1 is the MKV video codec, avif is the "
                        "image format); audio takes mp3, aac, m4a, opus, ogg, flac, wav or aiff. Where the "
                        "converted file lands follows Clop's convert placement setting unless "
                        "convertBehaviour says otherwise. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}},
            "kind": {"type": "string", "description": "image, video or audio"},
            "to": {"type": "string", "description": "the target format"},
            "compression": {"type": "string", "description": "5 to 100"},
            "bitrate": {"type": "integer", "description": "audio only, kbps. Beats compression"},
            "convertBehaviour": {"type": "string", "description": "temp, inplace, samefolder or specificfolder"},
            "copy": {"type": "boolean"},
            "recursive": {"type": "boolean"},
            "types": {"type": "string"},
            "output": {"type": "string"},
            "skipErrors": {"type": "boolean"}},
            "required": ["paths", "kind", "to"]},
        "handler": clop_convert,
    },
    {
        "name": "clop_crop",
        "description": ("Crop and optimise images, videos and PDFs to a size or an aspect ratio. size takes "
                        "WxH (1920x1080), a ratio (16:9), or a single number with longEdge. smartCrop keeps "
                        "the interesting part of the frame rather than the centre. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}},
            "size": {"type": "string", "description": "WxH, a ratio like 16:9, or a single number with longEdge"},
            "longEdge": {"type": "boolean", "description": "read size as the long edge"},
            "smartCrop": {"type": "boolean"},
            "removeAudio": {"type": "boolean"},
            "aggressive": {"type": "boolean"},
            "copy": {"type": "boolean"},
            "recursive": {"type": "boolean"},
            "types": {"type": "string"},
            "output": {"type": "string"},
            "skipErrors": {"type": "boolean"}},
            "required": ["paths", "size"]},
        "handler": clop_crop,
    },
    {
        "name": "clop_strip_exif",
        "description": ("Delete EXIF metadata from images and videos, in place. Location, camera and "
                        "timestamps go with it, so say what it removes before running it over someone's "
                        "library. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}},
            "recursive": {"type": "boolean"},
            "types": {"type": "string"}},
            "required": ["paths"]},
        "handler": clop_strip_exif,
    },
    {
        "name": "clop_crop_pdf",
        "description": ("Crop PDFs to a device screen, a paper size or an aspect ratio, without optimising "
                        "them. Non-destructive and reversible with clop_uncrop_pdf, since it only moves the "
                        "crop box. Rewrites the file in place unless output says otherwise. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}},
            "forDevice": {"type": "string", "description": "e.g. iPad Air"},
            "paperSize": {"type": "string", "description": "e.g. A4, Letter"},
            "aspectRatio": {"type": "string", "description": "e.g. 1640x2360 or 16:9"},
            "pageLayout": {"type": "string", "description": "portrait, landscape or auto"},
            "extend": {"type": "boolean", "description": "extend the page instead of cutting into it"},
            "recursive": {"type": "boolean"},
            "output": {"type": "string"}},
            "required": ["paths"]},
        "handler": clop_crop_pdf,
    },
    {
        "name": "clop_uncrop_pdf",
        "description": "Restore PDFs to their original size by removing the crop box. " + GATE,
        "inputSchema": {"type": "object", "properties": {
            "paths": {"type": "array", "items": {"type": "string"}},
            "recursive": {"type": "boolean"},
            "output": {"type": "string"}},
            "required": ["paths"]},
        "handler": lambda a: text(["uncrop-pdf"] + _paths(a)
                                  + _flag(a, "recursive", "--recursive")
                                  + _opt(a, "--output", "output"),
                                  timeout=FILE_TIMEOUT),
    },
    # --- pipelines
    {
        "name": "clop_pipeline_prompt",
        "description": ("Clop's own reference for writing a pipeline: every step, its parameters, the values "
                        "each one accepts and the caveats. Read this before authoring or editing any "
                        "pipeline, and reach for a script step only when no built-in step can do the job. "
                        "Pass compact for the short version."),
        "inputSchema": {"type": "object", "properties": {
            "task": {"type": "string", "description": "what the pipeline should do, appended as the task"},
            "compact": {"type": "boolean", "description": "the short reference instead of the full one"}}},
        "handler": lambda a: text(["pipeline", "prompt"]
                                  + (["--compact"] if a.get("compact") else [])
                                  + ([a["task"]] if a.get("task") else []),
                                  timeout=45),
    },
    {
        "name": "clop_pipeline_list",
        "description": ("Saved pipelines and folder automations, with the DSL each one runs. An automation "
                        "carrying only a libraryID is a reference to a saved pipeline, so resolve it against "
                        "the saved list by id rather than reading it as an empty pipeline."),
        "inputSchema": {"type": "object", "properties": {
            "all": {"type": "boolean", "description": "also show orphaned automations and broken references"}}},
        "handler": lambda a: run(["pipeline", "list"] + _flag(a, "all", "--all")),
    },
    {
        "name": "clop_pipeline_show",
        "description": "The steps of one saved pipeline, by name.",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
        "handler": lambda a: run(["pipeline", "show", a["name"]]),
    },
    {
        "name": "clop_pipeline_run",
        "description": ("Run a pipeline over files: a saved pipeline by name, or inline DSL steps as one "
                        "string. Inline pipelines run exactly the steps written, with no implicit optimise "
                        "pass, so include an optimise step when one is wanted. Read clop_pipeline_prompt "
                        "before writing inline steps, and try a draft on one file before a folder. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "pipeline": {"type": "string", "description": "a saved pipeline name, or inline DSL steps"},
            "paths": {"type": "array", "items": {"type": "string"}},
            "recursive": {"type": "boolean"},
            "types": {"type": "string"},
            "hideResult": {"type": "boolean", "description": "do not show the floating result"},
            "optimiseBehaviour": {"type": "string"},
            "convertBehaviour": {"type": "string"},
            "skipErrors": {"type": "boolean"}},
            "required": ["pipeline", "paths"]},
        "handler": clop_pipeline_run,
    },
    {
        "name": "clop_pipeline_write",
        "description": ("Ask Clop to save a pipeline to the library, so it can be run by name, attached to a "
                        "folder or hung on a drop zone. steps is the DSL string: read clop_pipeline_prompt "
                        "first, and use a built-in step whenever one can do the job, saying which one was "
                        "tried before reaching for a script. A script step is arbitrary code Clop runs and "
                        "sits behind its own switch, separate from the MCP switch, so a pipeline carrying one "
                        "is refused until the user allows script steps and Clop says which step it refused. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "name": {"type": "string"},
            "steps": {"type": "string", "description": "the pipeline DSL, one string"},
            "fileType": {"type": "string", "description": "image, video, pdf or audio. Omit for any type"},
            "skipOptimisation": {"type": "boolean", "description": "run only the written steps"},
            "hideResult": {"type": "boolean"},
            "replace": {"type": "boolean", "description": "replace a pipeline of the same name"}},
            "required": ["name", "steps"]},
        "handler": clop_pipeline_write,
    },
    {
        "name": "clop_pipeline_delete",
        "description": "Delete a saved pipeline by name. " + GATE,
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
        "handler": lambda a: text(["pipeline", "delete", a["name"]], timeout=60),
    },
    {
        "name": "clop_pipeline_attach",
        "description": ("Bind a pipeline to a source for one file type: the clipboard, the drop zone, or a "
                        "folder path. A folder source also starts watching that folder and switches automatic "
                        "processing on for that type, so every matching file dropped there is processed from "
                        "then on. Say that to the user before attaching one. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "pipeline": {"type": "string", "description": "a saved pipeline name or id, or inline DSL steps"},
            "source": {"type": "string", "description": "clipboard, dropZone, or an absolute folder path"},
            "type": {"type": "string", "description": "image, video, pdf or audio"},
            "skipOptimisation": {"type": "boolean"},
            "hideResult": {"type": "boolean"}},
            "required": ["pipeline", "source", "type"]},
        "handler": clop_pipeline_attach,
    },
    {
        "name": "clop_pipeline_detach",
        "description": ("Remove one attached pipeline, by its 0-based index, or all of them for that source "
                        "and type. clop_pipeline_list shows what is attached where. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "source": {"type": "string", "description": "clipboard, dropZone, or an absolute folder path"},
            "type": {"type": "string", "description": "image, video, pdf or audio"},
            "index": {"type": "integer", "description": "0-based, from clop_pipeline_list"},
            "all": {"type": "boolean"}},
            "required": ["source", "type"]},
        "handler": clop_pipeline_detach,
    },
    {
        "name": "clop_pipeline_preset",
        "description": ("Add or remove a preset zone on the drop zone: a named target the user drops files on "
                        "to run one pipeline. Omit type for a zone that takes every file type. " + GATE),
        "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "description": "add or remove. Default add"},
            "name": {"type": "string", "description": "the zone's label"},
            "pipeline": {"type": "string", "description": "a saved pipeline name or id, or inline DSL steps"},
            "type": {"type": "string", "description": "image, video, pdf or audio. Omit for all types"},
            "icon": {"type": "string", "description": "SF Symbol name, default wand.and.stars"},
            "skipOptimisation": {"type": "boolean"},
            "hideResult": {"type": "boolean"},
            "replace": {"type": "boolean"}},
            "required": ["name"]},
        "handler": clop_pipeline_preset,
    },
]

TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# ----- JSON-RPC / MCP plumbing -------------------------------------------------

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def reply(id, result):
    send({"jsonrpc": "2.0", "id": id, "result": result})


def error(id, code, message):
    send({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})


def handle_initialize(mid, params):
    # Only a string. A client sending a number here used to poison every later version
    # comparison, so an elicitation-capable tool failed with a Python type error.
    _v = params.get("protocolVersion")
    STATE.protocol = _v if isinstance(_v, str) else DEFAULT_PROTOCOL
    STATE.modes = elicitation_modes(params.get("capabilities") or {})
    STATE.client_name = (params.get("clientInfo") or {}).get("name") or ""
    reply(mid, {
        "protocolVersion": STATE.protocol,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    })


def call_tool(mid, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    tool = TOOLS_BY_NAME.get(name)
    if not tool:
        reply(mid, {"content": [{"type": "text", "text": f"unknown tool: {name}"}], "isError": True})
        return

    # Checked from the tool's own schema rather than in each handler, so a missing argument names
    # itself. Without this the agent was handed a raw Python KeyError, "tool error: 'key'", which
    # names nothing it can act on.
    missing = [
        field for field in (tool["inputSchema"].get("required") or [])
        if args.get(field) in (None, "")
    ]
    if missing:
        reply(mid, {
            "content": [{"type": "text", "text": f"{name} needs {', '.join(missing)}"}],
            "isError": True,
        })
        return

    previous = (CURRENT.request_id, CURRENT.name, CURRENT.args, CURRENT.params)
    CURRENT.request_id, CURRENT.name, CURRENT.args, CURRENT.params = mid, name, args, params
    DEPTH.value += 1
    try:
        result = tool["handler"](args)
        # The prose sentinel, so a DSL reference arrives readable rather than as an
        # escaped JSON string.
        if isinstance(result, dict) and set(result) == {"output"}:
            body = result["output"]
        else:
            body = json.dumps(result, indent=2)
        reply(mid, {"content": [{"type": "text", "text": body}]})
    except NeedInput as need:
        reply(mid, {
            "resultType": "input_required",
            "inputRequests": {need.key: {"method": "elicitation/create",
                                         "params": {"mode": "form", "message": need.message,
                                                    "requestedSchema": need.schema}}},
            "requestState": seal_state(name, args),
        })
    except ClopError as e:
        # Clop's own words, with no prefix: they are what the agent should read.
        reply(mid, {"content": [{"type": "text", "text": str(e)}], "isError": True})
    except Exception as e:
        reply(mid, {"content": [{"type": "text", "text": f"tool error: {e}"}], "isError": True})
    finally:
        DEPTH.value -= 1
        CURRENT.request_id, CURRENT.name, CURRENT.args, CURRENT.params = previous


def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    is_request = "id" in msg          # presence, not truthiness: id 0 is a real id

    if method == "initialize":
        handle_initialize(mid, msg.get("params") or {})
    elif method == "notifications/initialized":
        pass                          # notification, no reply
    elif method == "notifications/cancelled":
        on_cancelled(msg.get("params"))
    elif method == "ping":
        reply(mid, {})
    elif method == "tools/list":
        reply(mid, {"tools": [{"name": t["name"], "description": t["description"],
                               "inputSchema": t["inputSchema"]} for t in TOOLS]})
    elif method == "tools/call":
        call_tool(mid, msg.get("params") or {})
    elif method is None:
        # A message with an id and no method is a RESPONSE, never a request. This happens when an
        # elicitation answer arrives after the pump gave up on it. Answering it would mean sending a
        # reply to a reply, which clients may surface as a server fault.
        log("ignoring late or unmatched response", mid)
    elif is_request:
        error(mid, -32601, f"method not found: {method}")
    # else: unknown notification, ignore


def dispatch(msg):
    """Route one message. Returns the pending elicitation id it answered, or None.

    Both the outer loop and the nested pump call this, so the servicing rules live
    in one place and a tools/call that arrives while a dialog is up is still served.
    """
    mid = msg.get("id")
    if isinstance(mid, str) and mid in PENDING and ("result" in msg or "error" in msg):
        PENDING[mid] = msg
        return mid
    handle(msg)
    return None


def main():
    log("starting")
    while True:
        try:
            line = READER.next_line()
        except EOFError:
            break
        line = line.strip()
        if not line:
            continue
        msg = parse(line)
        if msg is None:
            continue          # malformed, and no id to reply to
        try:
            dispatch(msg)
        except SystemExit:
            break
        except Exception as e:
            log("handler crashed:", e)


if __name__ == "__main__":
    main()
