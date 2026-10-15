"""Content-checked development caches; course scripts and RTL stay unchanged."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import time

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else _digest(stream)


def _digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(block)
    return result.hexdigest()


def identities(paths):
    return {Path(p).resolve().as_posix(): digest(p) for p in dict.fromkeys(paths)}


def rtl_dependencies(sources):
    """Track literal includes too; refuse unknown macro includes for safe reuse."""
    result = []
    pending = list(sources)
    while pending:
        path = Path(pending.pop()).resolve()
        if path in result:
            continue
        result.append(path)
        source = re.sub(r"/\*.*?\*/|//[^\n]*", "", path.read_text(), flags=re.S)
        for match in re.finditer(r'`include\s+([^\n]+)', source):
            literal = re.fullmatch(r'"([^"\n]+)"\s*', match[1])
            if not literal:
                raise ValueError(f"cache requires a literal include path: {path}: {match[0]}")
            candidates = [path.parent / literal[1], ROOT / literal[1]]
            included = next((p for p in candidates if p.is_file()), None)
            if included is None:
                raise ValueError(f"cannot resolve include dependency: {path}: {literal[1]}")
            pending.append(included)
    return result


def read_json(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def valid_record(path, identity):
    record = read_json(path)
    if record.get("identity") != identity or not record.get("artifacts"):
        return False
    try:
        return all(digest(p) == expected for p, expected in record["artifacts"].items())
    except OSError:
        return False


def save_record(path, identity, artifacts):
    write_json(path, {"identity": identity, "artifacts": identities(artifacts)})


@contextmanager
def locked(directory):
    """OS locks release on process exit, including interrupted/failed builds."""
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".flow.lock").open("a+b") as stream:
        stream.seek(0, os.SEEK_END)
        if stream.tell() == 0:
            stream.write(b"0")
            stream.flush()
        warned = False
        while True:
            try:
                stream.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if not warned:
                    print(f"Waiting for build lock: {directory}", flush=True)
                    warned = True
                time.sleep(0.2)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
