"""Validation limits for recorded speech sent through the private cmux proxy."""

from __future__ import annotations

import struct

# The iOS recorder produces mono 16 kHz, 16-bit WAV. Ten minutes is about
# 19.2 MB, so this keeps the existing long-form recorder while putting a hard
# ceiling on every hop of the transcription pipeline.
MAX_VOICE_AUDIO_BYTES = 20 * 1024 * 1024
MAX_VOICE_JSON_BYTES = 29 * 1024 * 1024
MAX_TRANSCRIPT_CHARACTERS = 131_072
VOICE_SAMPLE_RATE = 16_000
VOICE_CHANNEL_COUNT = 1
VOICE_BITS_PER_SAMPLE = 16
MAX_VOICE_DURATION_SECONDS = 10 * 60


class VoiceError(ValueError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "invalid_voice_recording",
        status: int = 400,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def validate_voice_wav(data: bytes) -> None:
    """Validate the exact bounded PCM format emitted by the iOS recorder."""

    if not isinstance(data, bytes) or len(data) < 44:
        raise VoiceError("recording must be a valid WAV file")
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise VoiceError("recording must be a valid WAV file")
    declared_size = struct.unpack_from("<I", data, 4)[0] + 8
    if declared_size != len(data):
        raise VoiceError("recording WAV size is invalid")

    offset = 12
    format_values = None
    data_bytes = None
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + chunk_size
        if payload_end > len(data):
            raise VoiceError("recording WAV chunks are invalid")
        if chunk_id == b"fmt " and format_values is None:
            if chunk_size < 16:
                raise VoiceError("recording WAV format is invalid")
            format_values = struct.unpack_from("<HHIIHH", data, payload_start)
        elif chunk_id == b"data" and data_bytes is None:
            data_bytes = chunk_size
        offset = payload_end + (chunk_size & 1)

    if offset != len(data) or format_values is None or not data_bytes:
        raise VoiceError("recording WAV chunks are invalid")

    audio_format, channels, sample_rate, byte_rate, block_align, bits = format_values
    expected_block_align = VOICE_CHANNEL_COUNT * (VOICE_BITS_PER_SAMPLE // 8)
    expected_byte_rate = VOICE_SAMPLE_RATE * expected_block_align
    if (
        audio_format != 1
        or channels != VOICE_CHANNEL_COUNT
        or sample_rate != VOICE_SAMPLE_RATE
        or byte_rate != expected_byte_rate
        or block_align != expected_block_align
        or bits != VOICE_BITS_PER_SAMPLE
        or data_bytes % block_align != 0
        or data_bytes / byte_rate > MAX_VOICE_DURATION_SECONDS
    ):
        raise VoiceError("recording must be mono 16 kHz, 16-bit PCM WAV")
