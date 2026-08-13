"""Extractors for the ai-ingest pipeline — one module per source type.
Each exposes can_handle(path) -> bool and extract(path) -> dict with
"text" and "metadata" keys. See ingest.py for how these are dispatched.
"""
