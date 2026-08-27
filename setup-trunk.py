#!/usr/bin/env python3
"""setup-trunk.py — compatibility shim for `pbx trunk`.

The trunk wizard now lives in the unified front-end `pbx`, so there is
one tool to learn instead of three. This wrapper is kept for compatibility with docs and existing habits that
refer to it by name; it simply forwards.

    sudo ./setup-trunk.py add       ==  sudo ./pbx trunk add
    sudo ./setup-trunk.py list      ==  sudo ./pbx trunk list
    sudo ./setup-trunk.py remove    ==  sudo ./pbx trunk remove
"""
import os
import sys

PBX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pbx")
if not os.path.exists(PBX):
    sys.exit(f"error: {PBX} not found — extract the full tarball and run from that directory")
os.execv("/usr/bin/python3", ["python3", PBX, "trunk", *(sys.argv[1:] or ["add"])])
