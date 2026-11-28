#!/usr/bin/env python3
"""Compatibility entry point for the isolated backend smoke."""
import os
from pathlib import Path
import sys

if __name__ == "__main__":
    os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name("run-live-smoke.py")), *sys.argv[1:]])
