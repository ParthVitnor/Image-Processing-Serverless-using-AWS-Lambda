"""
Image Processing Lambda Function
─────────────────────────────────
Triggered by S3 ObjectCreated events on the source bucket.
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
  - PIL.UnidentifiedImageError → logged as warning, record skipped (no retry value).
  - All other exceptions per record → logged with full traceback, collected, and
    re-raised at the end so the invocation is marked failed and routes to the DLQ.
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
    # Keep RGBA so transparent source images are preserved in the PNG output.
    buf = io.BytesIO()
    img.convert("RGBA").save(buf, format="PNG", optimize=True)
    _upload(buf, f"{base}.png", "image/png")

    # ── Thumbnail 200×200 ────────────────────────────────────────────────────
    thumb = img.copy()
    thumb.thumbnail((THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT), Image.LANCZOS)
    buf = io.BytesIO()
    # Convert to RGB for JPEG output (JPEG does not support alpha channel)
    thumb.convert("RGB").save(buf, format="JPEG", quality=85)
    _upload(buf, f"{base}_thumb_{THUMBNAIL_WIDTH}x{THUMBNAIL_HEIGHT}.jpg", "image/jpeg")


# ─── entry point ──────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Process each S3 record independently.

    Strategy:
    - UnidentifiedImageError  → warn + skip (the file is not an image;
      retrying won't fix it, so we do not fail the invocation).
    - Any other exception      → log full traceback, collect the key, and
      re-raise a summary RuntimeError after all records are attempted so the
      invocation fails and the async retry / DLQ mechanism fires.
    """
    failed_keys: list[str] = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        logger.info("Processing s3://%s/%s", bucket, key)

        try:
            response   = s3.get_object(Bucket=bucket, Key=key)
            image_data = response["Body"].read()

            # Open and fully decode the image upfront so any corrupt-file or
            # format errors are caught here, in one place, before we start
            # writing any output variants.
            img = Image.open(io.BytesIO(image_data))
            img.load()  # forces full pixel decode; raises on corrupt data

            process_image(img, _base_key(key))

        except UnidentifiedImageError:
            # File extension matched but content is not a recognisable image.
            # No point retrying — skip and move on.
            logger.warning(
                "Skipping s3://%s/%s — not a recognised image format",
                bucket, key,
            )

        except Exception:  # noqa: BLE001
            # S3 errors, OOM, unexpected PIL failures, etc.
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
