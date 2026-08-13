"""
ai-ingest/extractors/documents.py

DOCX / PDF / TXT / MD extraction via Docling. Docling also handles OCR
for scanned PDFs as part of its normal document conversion — no
separate fallback needed at this layer for scanned PDFs specifically
(pytesseract fallback is for the images.py extractor, where Docling's
OCR path can fail or return empty text more often on non-document
images).
"""

from pathlib import Path

from docling.document_converter import DocumentConverter

SUPPORTED_EXTENSIONS = {".docx", ".pdf", ".txt", ".md"}

_converter = None


def _get_converter() -> DocumentConverter:
    # Lazily constructed and reused across calls — Docling's converter
    # setup isn't free, and ingest.py calls this once per file in a
    # single process run.
    global _converter
    if _converter is None:
        _converter = DocumentConverter()
    return _converter


def can_handle(path: Path) -> bool:
    return path.suffix.lower() in SUPPORTED_EXTENSIONS


def extract(path: Path) -> dict:
    """Returns {"text": str, "metadata": dict}. Raises on failure —
    caller (ingest.py) is responsible for catching and recording the
    failure in the manifest."""
    suffix = path.suffix.lower()

    if suffix in (".txt", ".md"):
        # Plain text — no need to route these through Docling's document
        # conversion pipeline at all.
        text = path.read_text(encoding="utf-8", errors="replace")
        return {
            "text": text,
            "metadata": {
                "extractor": "plain-text-read",
                "source_format": suffix.lstrip("."),
            },
        }

    converter = _get_converter()
    result = converter.convert(str(path))
    doc = result.document
    text = doc.export_to_markdown()

    metadata = {
        "extractor": "docling",
        "source_format": suffix.lstrip("."),
    }
    # Page count is useful downstream (e.g. flagging suspiciously short
    # extractions from long PDFs as likely OCR failures) — grab it if
    # Docling's document object exposes it, but don't fail extraction
    # if the attribute isn't there on this Docling version.
    try:
        metadata["page_count"] = len(doc.pages)
    except (AttributeError, TypeError):
        pass

    return {"text": text, "metadata": metadata}
