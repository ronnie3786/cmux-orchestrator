import io
import unittest
import wave

from herdr_harness import voice


def _wav(*, channels=1, sample_rate=16_000, sample_width=2, frames=160) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(channels)
        audio.setsampwidth(sample_width)
        audio.setframerate(sample_rate)
        audio.writeframes(b"\x00" * frames * channels * sample_width)
    return buffer.getvalue()


class HerdrVoiceValidationTests(unittest.TestCase):
    def test_accepts_bounded_mono_pcm_recording(self):
        voice.validate_voice_wav(_wav())

    def test_rejects_wrong_audio_format(self):
        for payload in (
            _wav(channels=2),
            _wav(sample_rate=44_100),
            _wav(sample_width=1),
        ):
            with self.subTest(size=len(payload)):
                with self.assertRaisesRegex(voice.VoiceError, "mono 16 kHz"):
                    voice.validate_voice_wav(payload)

    def test_rejects_forged_or_truncated_riff(self):
        valid = _wav()
        for payload in (b"RIFF\x04\x00\x00\x00WAVE", valid[:-1], valid + b"extra"):
            with self.subTest(size=len(payload)):
                with self.assertRaises(voice.VoiceError):
                    voice.validate_voice_wav(payload)


if __name__ == "__main__":
    unittest.main()
