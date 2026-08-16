/**
 * Voice note helpers — pure functions ported from cmux-harness-ios
 * Views/Input/VoiceNoteRecorder.swift (recording limits, waveform sampling,
 * duration formatting, output filename).
 */

/** iOS VoiceNoteRecorder.maxDuration: 10 * 60. */
export const VOICE_NOTE_MAX_SECONDS = 10 * 60;

/** iOS VoiceNoteRecorder.waveformSampleCount. */
export const WAVEFORM_SAMPLE_COUNT = 44;

/** iOS baselineSamples(): 44 bars at 0.08. */
export function baselineWaveformSamples(): number[] {
  return new Array<number>(WAVEFORM_SAMPLE_COUNT).fill(0.08);
}

/**
 * Port of VoiceNoteRecorder.normalizedLevel(fromPower:).
 *
 * iOS normalizes averagePower (dBFS, 0 = full scale) clamped to [-50, 0]
 * through 10^(db/35), then clamps to [0.08, 1]. On the web the dB value comes
 * from the analyser's time-domain RMS (see sampleLevel).
 */
export function normalizedLevelFromDb(db: number): number {
  const clamped = Math.min(Math.max(db, -50), 0);
  const linear = Math.pow(10, clamped / 35);
  return Math.min(Math.max(linear, 0.08), 1);
}

/**
 * One waveform sample from an AnalyserNode time-domain buffer.
 *
 * RMS → dBFS → normalizedLevelFromDb (the web analog of
 * `recorder.updateMeters()` + `averagePower(forChannel: 0)`).
 */
export function sampleLevel(timeDomain: Float32Array): number {
  if (timeDomain.length === 0) return 0.08;
  let sum = 0;
  for (let i = 0; i < timeDomain.length; i += 1) {
    const value = timeDomain[i];
    sum += value * value;
  }
  const rms = Math.sqrt(sum / timeDomain.length);
  if (!Number.isFinite(rms) || rms <= 0) return 0.08;
  return normalizedLevelFromDb(20 * Math.log10(rms));
}

/**
 * Pick the best supported MediaRecorder mime type.
 * Preference: audio/webm;codecs=opus → audio/webm → default (empty string).
 */
export function pickRecorderMimeType(): string {
  const candidates = ["audio/webm;codecs=opus", "audio/webm"];
  const isSupported = (type: string): boolean => {
    try {
      return MediaRecorder.isTypeSupported(type);
    } catch {
      return false;
    }
  };
  for (const candidate of candidates) {
    if (isSupported(candidate)) return candidate;
  }
  return "";
}

/** Port of VoiceNoteRecorderSheet.formattedDuration: floored `m:ss`. */
export function formatVoiceDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(total / 60);
  const remainder = total % 60;
  return `${minutes}:${String(remainder).padStart(2, "0")}`;
}

/** File extension for a recorded audio mime type (iOS: .m4a; web: webm/opus). */
function extensionForMime(mime: string): string {
  const normalized = (mime || "").toLowerCase();
  if (normalized.includes("ogg")) return "ogg";
  if (normalized.includes("mp4") || normalized.includes("aac")) return "m4a";
  return "webm";
}

/**
 * Port of VoiceNoteRecorder.makeVoiceNoteURL naming:
 * `voice-note-<epoch-seconds>-<8hex>.<ext>`.
 */
export function voiceNoteFilename(mime: string, now: Date = new Date()): string {
  const timestamp = Math.floor(now.getTime() / 1000);
  const random = (globalThis.crypto?.getRandomValues
    ? Array.from(globalThis.crypto.getRandomValues(new Uint8Array(4)))
    : Array.from({ length: 4 }, () => Math.floor(Math.random() * 256))
  )
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `voice-note-${timestamp}-${random}.${extensionForMime(mime)}`;
}
