"""Optional credential round-trip tests using the host's Python bcrypt."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import bcrypt

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="traefik-auth-test-") as folder:
    work = Path(folder)
    shutil.copy(ROOT / "traefik-basic-auth.sh", work)
    shutil.copytree(ROOT / "lib", work / "lib")
    (work / ".env").write_text("DATA_DIR=./data\nDASHBOARD_LOGIN=reviewer\n")
    env = dict(os.environ)
    env.pop("ENV_FILE", None)
    if "--docker-fallback" in sys.argv:
        tools = work / "bin"
        tools.mkdir()
        for command in ("sh", "dirname", "tr", "sed", "grep", "mkdir", "chmod", "mktemp", "rm", "mv", "wc", "openssl", "docker"):
            executable = shutil.which(command)
            assert executable, f"Missing {command}"
            (tools / command).symlink_to(executable)
        env["PATH"] = str(tools)
    auth = work / "data/auth/dashboard.htpasswd"

    def run(password):
        return subprocess.run(
            ["sh", str(work / "traefik-basic-auth.sh"), "--password-stdin"],
            input=password + b"\n", capture_output=True, env=env,
        )

    passwords = (
        b"quotes'\" backslash\\ dollar$ ampersand& slash/ backtick`",
        b"$(touch INJECTED)",
        b"x" * 72,
    )
    for password in passwords:
        result = run(password)
        assert result.returncode == 0, result.stderr.decode()
        username, hashed = auth.read_bytes().strip().split(b":", 1)
        assert username == b"reviewer"
        assert bcrypt.checkpw(password, hashed)
        assert password not in result.stdout + result.stderr, "Password leaked to output"
        assert not (work / "INJECTED").exists(), "Password was executed"
    print("PASS: special characters, shell syntax, and 72-byte passwords round-trip through bcrypt")

    saved = auth.read_bytes()
    for password in (b"", b"x" * 73):
        assert run(password).returncode != 0
        assert auth.read_bytes() == saved, "Invalid password replaced existing credentials"
    print("PASS: empty and oversized passwords preserve working credentials")

    generated = subprocess.run(
        ["sh", str(work / "traefik-basic-auth.sh"), "--generate"],
        capture_output=True, env=env,
    )
    assert generated.returncode == 0, generated.stderr.decode()
    password_file = work / "data/auth/dashboard-password.txt"
    password = password_file.read_bytes().strip()
    assert len(password) == 48
    assert bcrypt.checkpw(password, auth.read_bytes().strip().split(b":", 1)[1])
    assert password not in generated.stdout + generated.stderr
    if os.name == "posix":
        assert auth.stat().st_mode & 0o777 == 0o600
        assert password_file.stat().st_mode & 0o777 == 0o600
    print("PASS: generated password authenticates, remains out of logs, and uses restricted storage")
