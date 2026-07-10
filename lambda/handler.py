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
"""

import os
import io
import logging
import urllib.parse

import boto3
from PIL import Image

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

DESTINATION_BUCKET = os.environ["DESTINATION_BUCKET"]
THUMBNAIL_WIDTH    = int(os.environ.get("THUMBNAIL_WIDTH",  "200"))
THUMBNAIL_HEIGHT   = int(os.environ.get("THUMBNAIL_HEIGHT", "200"))


def _base_key(key: str) -> str:
    """Strip the file extension from an S3 key."""
    return os.path.splitext(key)[0]


def _upload(buf: io.BytesIO, dest_key: str, content_type: str) -> None:
    buf.seek(0)
    s3.put_object(
        Bucket=dest_bucket(),
        Key=dest_key,
        Body=buf,
        ContentType=content_type,
    )
    logger.info("Uploaded s3://%s/%s", DESTINATION_BUCKET, dest_key)


def dest_bucket() -> str:
    return DESTINATION_BUCKET


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

    # ── Thumbnail 200×200 ─────────────────────────────────────────────────────
    thumb = img.copy()
    thumb.thumbnail((THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT), Image.LANCZOS)
    buf = io.BytesIO()
    thumb.convert("RGB").save(buf, format="JPEG", quality=85)
    _upload(buf, f"{base}_thumb_{THUMBNAIL_WIDTH}x{THUMBNAIL_HEIGHT}.jpg", "image/jpeg")


def lambda_handler(event, context):
    """Entry point — processes each S3 record in the event."""
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        logger.info("Processing s3://%s/%s", bucket, key)

        # Download original image
        response = s3.get_object(Bucket=bucket, Key=key)
        image_data = response["Body"].read()

        img = Image.open(io.BytesIO(image_data))
        base = _base_key(key)

        process_image(img, base)

    return {"statusCode": 200, "body": "Image processing complete"}
