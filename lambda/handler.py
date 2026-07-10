"""
Image Processing Lambda Function
─────────────────────────────────
Triggered by S3 PutObject events on the source bucket.
For every uploaded image it produces five variants in the destination bucket:
  • JPEG at quality 85   →  <key>_q85.jpg
  • JPEG at quality 60   →  <key>_q60.jpg
  • WebP                 →  <key>.webp
  • PNG                  →  <key>.png
  • Thumbnail 200×200    →  <key>_thumb_200x200.jpg

Environment variables (injected by Terraform):
  DESTINATION_BUCKET  – target S3 bucket name
  THUMBNAIL_WIDTH     – thumbnail width  (default 200)
  THUMBNAIL_HEIGHT    – thumbnail height (default 200)

Error handling:
  - Each S3 record is processed independently; one bad file does not abort others.
  - PIL.UnidentifiedImageError is caught and logged; the invocation still succeeds
    so S3 does not re-trigger and eventually route to the DLQ.
  - All unexpected exceptions per record are caught, logged with full traceback,
    and re-raised at the end so at least one failure makes the invocation fail
    (which feeds the DLQ / async retry mechanism).
"""

import io
import logging
import os
import traceback
import urllib.parse

import boto3
from PIL import Image, UnidentifiedImageError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

DESTINATION_BUCKET = os.environ["DESTINATION_BUCKET"]
THUMBNAIL_WIDTH    = int(os.environ.get("THUMBNAIL_WIDTH",  "200"))
THUMBNAIL_HEIGHT   = int(os.environ.get("THUMBNAIL_HEIGHT", "200"))


# ─── helpers ──────────────────────────────────────────────────────────────────

def _base_key(key: str) -> str:
    """Strip the file extension from an S3 key."""
    return os.path.splitext(key)[0]


def _upload(buf: io.BytesIO, dest_key: str, content_type: str) -> None:
    buf.seek(0)
    s3.put_object(
        Bucket=DESTINATION_BUCKET,
        Key=dest_key,
        Body=buf,
        ContentType=content_type,
    )
    logger.info("Uploaded s3://%s/%s", DESTINATION_BUCKET, dest_key)


# ─── image processing ─────────────────────────────────────────────────────────

def process_image(img: Image.Image, base: str) -> None:
    """Generate all five output variants from a PIL Image object."""

    # ── JPEG quality 85 ──────────────────────────────────────────────────────
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=85, optimize=True)
    _upload(buf, f"{base}_q85.jpg", "image/jpeg")

    # ── JPEG quality 60 ──────────────────────────────────────────────────────
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=60, optimize=True)
    _upload(buf, f"{base}_q60.jpg", "image/jpeg")

    # ── WebP ─────────────────────────────────────────────────────────────────
    buf = io.BytesIO()
    img.save(buf, format="WEBP", quality=85)
    _upload(buf, f"{base}.webp", "image/webp")

    # ── PNG ──────────────────────────────────────────────────────────────────
    buf = io.BytesIO()
    img.convert("RGBA").save(buf, format="PNG", optimize=True)
    _upload(buf, f"{base}.png", "image/png")

    # ── Thumbnail 200×200 ────────────────────────────────────────────────────
    thumb = img.copy()
    thumb.thumbnail((THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT), Image.LANCZOS)
    buf = io.BytesIO()
    thumb.convert("RGB").save(buf, format="JPEG", quality=85)
    _upload(buf, f"{base}_thumb_{THUMBNAIL_WIDTH}x{THUMBNAIL_HEIGHT}.jpg", "image/jpeg")


# ─── entry point ──────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Process each S3 record independently.

    Strategy:
    - UnidentifiedImageError  → log a warning and skip (not re-routable to DLQ,
      the upload was simply not an image — no point retrying).
    - Any other exception      → log with traceback, collect, and re-raise a
      summary at the end so the invocation is marked failed and the DLQ fires.
    """
    failed_keys: list[str] = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        logger.info("Processing s3://%s/%s", bucket, key)

        try:
            response   = s3.get_object(Bucket=bucket, Key=key)
            image_data = response["Body"].read()

            try:
                img = Image.open(io.BytesIO(image_data))
                # Fully load pixel data now so decode errors surface here,
                # not inside process_image midway through writing outputs.
                img.load()
            except UnidentifiedImageError:
                # The file has a matching extension but is not a valid image
                # (e.g. a text file renamed to .jpg).  Log and skip — retrying
                # won't help, so we do NOT add it to failed_keys.
                logger.warning(
                    "Skipping s3://%s/%s — not a recognised image format",
                    bucket, key,
                )
                continue

            process_image(img, _base_key(key))

        except Exception:  # noqa: BLE001
            # Catch everything else (S3 errors, OOM, unexpected PIL bugs, …)
            # Log full traceback for CloudWatch, then collect for re-raise.
            logger.error(
                "Failed to process s3://%s/%s:\n%s",
                bucket, key, traceback.format_exc(),
            )
            failed_keys.append(f"s3://{bucket}/{key}")

    if failed_keys:
        raise RuntimeError(
            f"Image processing failed for {len(failed_keys)} file(s): "
            + ", ".join(failed_keys)
        )

    return {"statusCode": 200, "body": "Image processing complete"}
