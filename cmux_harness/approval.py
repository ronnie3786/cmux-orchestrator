"""Approval classification (deprecated).

Auto/Super Auto approval decisions now run through
:mod:`cmux_harness.auto_policy` from the terminal polling loop. The Claude
Code PreToolUse endpoint is only a compatibility shim that exposes the normal
terminal approval prompt for polling.
"""
