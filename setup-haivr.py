#!/usr/bin/env python3
"""setup-haivr.py — compatibility shim for `pbx haivr`.

The ha_ivr wizard now lives in the unified front-end `pbx`, so there is
one tool to learn instead of three. This wrapper is kept for compatibility with docs and existing habits that
refer to it by name; it simply forwards.

    sudo ./setup-haivr.py           ==  sudo ./pbx haivr set
    sudo ./setup-haivr.py show      ==  sudo ./pbx haivr show
    sudo ./setup-haivr.py test      ==  sudo ./pbx haivr test
"""
import os
import sys

PBX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pbx")
if not os.path.exists(PBX):
    sys.exit(f"error: {PBX} not found — extract the full tarball and run from that directory")
os.execv("/usr/bin/python3", ["python3", PBX, "haivr", *(sys.argv[1:] or ["set"])])
