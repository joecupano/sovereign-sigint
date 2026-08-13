"""
ai-ingest/extractors/images.py

OCR for static images (GIF, PNG, JPG, JPEG, HEIC, etc. — see
/data/imagery in docs/data-layout.md). Docling is tried first since
it's already a dependency for documents.py and generally produces
better-structured output; pytesseract is the fallback when Docling's
OCR path fails outright or returns suspiciously little text (a common
failure mode on non-document photos Docling wasn't primarily built for).
"""

from pathlib import Path

from PIL import Image
import pytesseract

try:
    import pillow_heif

    pillow_heif.register_heif_opener()  # lets PIL.Image.open() read HEIC/HEIF
    _HEIC_SUPPORTED = True
except ImportError:
    _HEIC_SUPPORTED = False

SUPPORTED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".heic", ".bmp", ".tiff", ".webp"}

# Below this character count, treat a Docling result as likely-failed
# and fall back to pytesseract rather than trust a near-empty result.
# Arbitrary but reasonable threshold — revisit if real-world images
# show this triggering false fallbacks or missing real failures.
MIN_PLAUSIBLE_TEXT_LENGTH = 3


def can_handle(path: Path) -> bool:
    ext = path.suffix.lower()
    if ext == ".heic" and not _HEIC_SUPPORTED:
        return False
    return ext in SUPPORTED_EXTENSIONS


def _try_docling(path: Path) -> str | None:
    try:
        from docling.document_converter import DocumentConverter
    except ImportError:
        return None
    try:
        converter = DocumentConverter()
        result = converter.convert(str(path))
        text = result.document.export_to_markdown().strip()
        return text if len(text) >= MIN_PLAUSIBLE_TEXT_LENGTH else None
    except Exception:
        # Docling isn't guaranteed to handle every image format/content
        # cleanly — any failure here just means "fall back," not "this
        # extraction failed." The overall extraction only actually fails
        # if pytesseract also fails, in extract() below.
        return None


def _pytesseract_ocr(path: Path) -> str:
    with Image.open(path) as img:
        return pytesseract.image_to_string(img)


def extract(path: Path) -> dict:
    """Returns {"text": str, "metadata": dict}. Raises only if BOTH
    Docling and pytesseract fail to produce usable text."""
    docling_text = _try_docling(path)
    if docling_text:
        return {
            "text": docling_text,
            "metadata": {"extractor": "docling-ocr", "source_format": path.suffix.lstrip(".").lower()},
        }

    tesseract_text = _pytesseract_ocr(path)
    return {
        "text": tesseract_text,
        "metadata": {
            "extractor": "pytesseract-fallback",
            "source_format": path.suffix.lstrip(".").lower(),
            "docling_attempted": True,
            "docling_result": "empty_or_failed",
        },
    }
