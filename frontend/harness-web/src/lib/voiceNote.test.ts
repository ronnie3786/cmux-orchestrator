import { describe, expect, it, vi } from "vitest";
import {
  baselineWaveformSamples,
  formatVoiceDuration,
  normalizedLevelFromDb,
  pickRecorderMimeType,
  sampleLevel,
  voiceNoteFilename,
  WAVEFORM_SAMPLE_COUNT,
} from "./voiceNote";

describe("normalizedLevelFromDb (iOS normalizedLevel port)", () => {
  it("maps full scale to 1 and the -50 dB floor to the 0.08 baseline", () => {
    expect(normalizedLevelFromDb(0)).toBe(1);
    // 10^(-50/35) ≈ 0.0371 → clamped to the 0.08 floor.
    expect(normalizedLevelFromDb(-50)).toBeCloseTo(0.08, 5);
  });

  it("clamps out-of-range dB values", () => {
    expect(normalizedLevelFromDb(12)).toBe(1);
    expect(normalizedLevelFromDb(-120)).toBeCloseTo(0.08, 5);
  });

  it("applies the 10^(db/35) curve in between", () => {
    // 10^(-35/35) = 0.1
    expect(normalizedLevelFromDb(-35)).toBeCloseTo(0.1, 5);
    // 10^(-70/35) = 0.01 → clamped to the 0.08 floor.
    expect(normalizedLevelFromDb(-70)).toBeCloseTo(0.08, 5);
  });
});

describe("sampleLevel (RMS → dB → normalized)", () => {
  it("returns the baseline for silence and empty buffers", () => {
    expect(sampleLevel(new Float32Array(0))).toBe(0.08);
    expect(sampleLevel(new Float32Array(1024))).toBe(0.08);
  });

  it("scales with signal amplitude", () => {
    const quiet = new Float32Array(1024).fill(0.01);
    const loud = new Float32Array(1024).fill(0.5);
    const quietLevel = sampleLevel(quiet);
    const loudLevel = sampleLevel(loud);
    expect(loudLevel).toBeGreaterThan(quietLevel);
    expect(loudLevel).toBeLessThanOrEqual(1);
    expect(quietLevel).toBeGreaterThanOrEqual(0.08);
  });
});

describe("baselineWaveformSamples", () => {
  it("produces 44 bars at 0.08 (iOS baselineSamples)", () => {
    const samples = baselineWaveformSamples();
    expect(samples).toHaveLength(WAVEFORM_SAMPLE_COUNT);
    expect(new Set(samples)).toEqual(new Set([0.08]));
  });
});

describe("formatVoiceDuration (iOS formattedDuration port)", () => {
  it("floors to m:ss", () => {
    expect(formatVoiceDuration(0)).toBe("0:00");
    expect(formatVoiceDuration(9.9)).toBe("0:09");
    expect(formatVoiceDuration(60)).toBe("1:00");
    expect(formatVoiceDuration(599.9)).toBe("9:59");
    expect(formatVoiceDuration(600)).toBe("10:00");
  });

  it("treats negative values as zero", () => {
    expect(formatVoiceDuration(-5)).toBe("0:00");
  });
});

describe("pickRecorderMimeType", () => {
  it("prefers audio/webm;codecs=opus, then audio/webm, then the default", () => {
    const isTypeSupported = vi
      .fn((type: string) => type === "audio/webm;codecs=opus" || type === "audio/webm");
    (globalThis as { MediaRecorder?: unknown }).MediaRecorder = { isTypeSupported };
    expect(pickRecorderMimeType()).toBe("audio/webm;codecs=opus");

    const webmOnly = vi.fn((type: string) => type === "audio/webm");
    (globalThis as { MediaRecorder?: unknown }).MediaRecorder = { isTypeSupported: webmOnly };
    expect(pickRecorderMimeType()).toBe("audio/webm");

    const none = vi.fn(() => false);
    (globalThis as { MediaRecorder?: unknown }).MediaRecorder = { isTypeSupported: none };
    expect(pickRecorderMimeType()).toBe("");

    // isTypeSupported throwing is treated as unsupported.
    const throwing = vi.fn(() => {
      throw new Error("nope");
    });
    (globalThis as { MediaRecorder?: unknown }).MediaRecorder = { isTypeSupported: throwing };
    expect(pickRecorderMimeType()).toBe("");
  });
});

describe("voiceNoteFilename (iOS makeVoiceNoteURL naming port)", () => {
  it("is voice-note-<epoch>-<8hex>.<ext> with an extension from the mime", () => {
    const now = new Date("2026-08-12T10:00:00.000Z");
    const filename = voiceNoteFilename("audio/webm;codecs=opus", now);
    expect(filename).toMatch(/^voice-note-1786528800-[0-9a-f]{8}\.webm$/);
    expect(voiceNoteFilename("audio/ogg", now)).toMatch(/\.ogg$/);
    expect(voiceNoteFilename("audio/mp4", now)).toMatch(/\.m4a$/);
    expect(voiceNoteFilename("", now)).toMatch(/\.webm$/);
  });
});
