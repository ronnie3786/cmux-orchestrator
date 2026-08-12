"""Shared validation limits for attachments proxied to the cmux API."""

from __future__ import annotations


MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
# A 20 MB payload expands to roughly 26.7 MB as base64. This limit includes
# the small surrounding JSON object while the rest of the API retains 1 MB.
MAX_ATTACHMENT_JSON_BYTES = 29 * 1024 * 1024


class AttachmentError(ValueError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "invalid_attachment",
        status: int = 400,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
