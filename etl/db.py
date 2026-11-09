"""Run SQL with libpq environment variables via the PostgreSQL client."""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*options, variables=None, script=None):
    command = [
        os.getenv("PSQL", "psql"), "--no-psqlrc", "--no-password", "--quiet",
        "--set=ON_ERROR_STOP=1",
    ]
    for name, value in (variables or {}).items():
        command.append(f"--set={name}={value}")
    command.extend(str(option) for option in options)
    return subprocess.run(
        command, input=script, text=True, stdout=subprocess.PIPE, check=True, cwd=ROOT
    ).stdout
