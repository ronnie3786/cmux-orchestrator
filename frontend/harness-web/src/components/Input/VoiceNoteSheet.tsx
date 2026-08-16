/**
 * VoiceNoteSheet — web port of cmux-harness-ios Views/Input/VoiceNoteRecorder
 * (+ VoiceNoteRecorderSheet).
 *
 * iOS: AVAudioEngine/AVAudioRecorder → 10-minute cap, 44 waveform samples
 * sampled every 0.1 s, baseline 0.08, normalizedLevel curve, live duration,
 * playable preview, discard confirmation once recording has started.
 *
 * Web parity: getUserMedia({audio}) + MediaRecorder (prefer
 * audio/webm;codecs=opus), WebAudio AnalyserNode RMS feeding the same 44-bar
 * waveform math (see lib/voiceNote.ts), 100 ms sampling tick, 10:00
 * auto-stop, <audio> preview with progress. The sheet is NOT
 * dismissible — like iOS (interactiveDismissDisabled), the only exits are
 * Save or Discard/Close.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { Check, Mic, Pause, Play, Square, Trash2, X } from "lucide-react";
import {
  baselineWaveformSamples,
  formatVoiceDuration,
  pickRecorderMimeType,
  sampleLevel,
  voiceNoteFilename,
  VOICE_NOTE_MAX_SECONDS,
  WAVEFORM_SAMPLE_COUNT,
} from "../../lib/voiceNote";

type RecorderStatus = "idle" | "recording" | "finished";

interface VoiceNoteSheetProps {
  /** Called with the recorded audio as a File — the caller adds it to the tray. */
  onSave: (file: File) => void;
  /** Called when the user exits without saving (discard/close). */
  onDismiss: () => void;
}

export function VoiceNoteSheet({ onSave, onDismiss }: VoiceNoteSheetProps) {
  const [status, setStatus] = useState<RecorderStatus>("idle");
  const [elapsed, setElapsed] = useState(0);
  const [samples, setSamples] = useState<number[]>(() => baselineWaveformSamples());
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [output, setOutput] = useState<{ blob: Blob; url: string } | null>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [playbackTime, setPlaybackTime] = useState(0);
  const [previewDuration, setPreviewDuration] = useState(0);
  const [confirmDiscard, setConfirmDiscard] = useState(false);

  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const timeBufferRef = useRef<Float32Array<ArrayBuffer>>(new Float32Array(0));
  const timerRef = useRef<number | null>(null);
  const startedAtRef = useRef(0);
  const disposedRef = useRef(false);
  const didSaveRef = useRef(false);
  const audioElRef = useRef<HTMLAudioElement | null>(null);

  // iOS hasStartedRecording: recording, or there is output, or time has run.
  const hasStartedRecording = status === "recording" || output !== null || elapsed > 0;
  const canSave = status === "finished" && output !== null && elapsed > 0;
  const limitLabel = formatVoiceDuration(VOICE_NOTE_MAX_SECONDS);

  /** Stop the mic stream + WebAudio context + sampling timer (idempotent). */
  const stopAudioResources = useCallback(() => {
    if (timerRef.current !== null) {
      window.clearInterval(timerRef.current);
      timerRef.current = null;
    }
    const stream = streamRef.current;
    streamRef.current = null;
    if (stream) {
      stream.getTracks().forEach((track) => track.stop());
    }
    const ctx = audioCtxRef.current;
    audioCtxRef.current = null;
    analyserRef.current = null;
    if (ctx && ctx.state !== "closed") {
      void ctx.close().catch(() => {
        /* already closed */
      });
    }
  }, []);

  /**
   * iOS appendLevelSample on the 0.1 s recordingTimer: advance the elapsed
   * counter, sample the analyser level, keep the last 44 samples, auto-stop
   * at the 10-minute cap.
   */
  const tick = useCallback(() => {
    const seconds = Math.min(
      (performance.now() - startedAtRef.current) / 1000,
      VOICE_NOTE_MAX_SECONDS,
    );
    setElapsed(seconds);

    let sample = 0.08;
    const analyser = analyserRef.current;
    if (analyser) {
      analyser.getFloatTimeDomainData(timeBufferRef.current);
      sample = sampleLevel(timeBufferRef.current);
    }
    setSamples((previous) => {
      const next = [...previous, sample];
      if (next.length > WAVEFORM_SAMPLE_COUNT) next.splice(0, next.length - WAVEFORM_SAMPLE_COUNT);
      return next;
    });

    if (seconds >= VOICE_NOTE_MAX_SECONDS) {
      stopRecordingRef.current(); // iOS maxDuration cap
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- stopRecording below; ref breaks the cycle
  }, []);

  /**
   * iOS stopRecording: clear the timer, stop the MediaRecorder — the onstop
   * handler finalizes (blob → finished, or empty → error + idle).
   */
  const stopRecording = useCallback(() => {
    if (timerRef.current !== null) {
      window.clearInterval(timerRef.current);
      timerRef.current = null;
    }
    const recorder = recorderRef.current;
    recorderRef.current = null;
    if (recorder && recorder.state !== "inactive") {
      recorder.stop();
      return;
    }
    stopAudioResources();
    if (recorder === null) {
      setStatus((previous) => (previous === "recording" ? "idle" : previous));
    }
  }, [stopAudioResources]);

  // tick → stopRecording → (timer) cycle: break it through a ref so both
  // callbacks stay referentially stable.
  const stopRecordingRef = useRef(stopRecording);
  useEffect(() => {
    stopRecordingRef.current = stopRecording;
  }, [stopRecording]);

  const startRecording = useCallback(async () => {
    setErrorMessage(null);
    setConfirmDiscard(false);

    // iOS discardCurrentFile(): drop the previous session's output first.
    if (output) {
      URL.revokeObjectURL(output.url);
      setOutput(null);
    }
    setIsPlaying(false);
    setPlaybackTime(0);
    setPreviewDuration(0);

    let stream: MediaStream;
    try {
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new DOMException("unsupported", "NotSupportedError");
      }
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (error) {
      const name = error instanceof DOMException ? error.name : "";
      if (name === "NotAllowedError" || name === "SecurityError") {
        setErrorMessage("Microphone access is required to record voice notes.");
      } else {
        setErrorMessage("Microphone unavailable. Check the browser microphone settings.");
      }
      return;
    }
    if (disposedRef.current) {
      stream.getTracks().forEach((track) => track.stop());
      return;
    }

    try {
      if (typeof MediaRecorder === "undefined") {
        throw new Error("Voice recording is not supported in this browser.");
      }
      const mimeType = pickRecorderMimeType();
      const recorder = new MediaRecorder(
        stream,
        mimeType === "" ? undefined : { mimeType },
      );
      const chunks: Blob[] = [];
      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) chunks.push(event.data);
      };
      recorder.onstop = () => {
        const finalSeconds = Math.min(
          (performance.now() - startedAtRef.current) / 1000,
          VOICE_NOTE_MAX_SECONDS,
        );
        const type = recorder.mimeType || mimeType || "audio/webm";
        const blob = new Blob(chunks, { type });
        stopAudioResources();
        if (disposedRef.current) return;
        if (blob.size === 0) {
          setErrorMessage("Recording failed.");
          setElapsed(0);
          setSamples(baselineWaveformSamples());
          setStatus("idle");
          return;
        }
        setOutput({ blob, url: URL.createObjectURL(blob) });
        setElapsed(finalSeconds);
        setPlaybackTime(0);
        setIsPlaying(false);
        setStatus("finished");
      };

      // iOS updateMeters analog: AnalyserNode time-domain RMS → dB → the
      // ported normalizedLevel curve (lib/voiceNote.sampleLevel).
      const Ctor =
        window.AudioContext ??
        (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (Ctor) {
        const ctx = new Ctor();
        const source = ctx.createMediaStreamSource(stream);
        const analyser = ctx.createAnalyser();
        analyser.fftSize = 1024;
        source.connect(analyser);
        audioCtxRef.current = ctx;
        analyserRef.current = analyser;
        timeBufferRef.current = new Float32Array(analyser.fftSize);
      }

      recorderRef.current = recorder;
      streamRef.current = stream;
      recorder.start(250);
      startedAtRef.current = performance.now();
      setElapsed(0);
      setPlaybackTime(0);
      setPreviewDuration(0);
      setSamples(baselineWaveformSamples());
      setStatus("recording");
      timerRef.current = window.setInterval(tick, 100);
    } catch (error) {
      stopAudioResources();
      stream.getTracks().forEach((track) => track.stop());
      setErrorMessage(
        error instanceof Error && error.message.length > 0 ? error.message : "Recording failed.",
      );
    }
  }, [output, stopAudioResources, tick]);

  const toggleRecording = useCallback(() => {
    if (status === "recording") {
      stopRecording();
    } else {
      void startRecording();
    }
  }, [status, startRecording, stopRecording]);

  const save = useCallback(() => {
    if (!canSave || output === null) return;
    didSaveRef.current = true;
    const file = new File([output.blob], voiceNoteFilename(output.blob.type), {
      type: output.blob.type,
    });
    onSave(file);
  }, [canSave, output, onSave]);

  // iOS discardAction: confirmation dialog once recording has started,
  // otherwise the sheet just closes.
  const requestDiscard = useCallback(() => {
    if (hasStartedRecording) {
      setConfirmDiscard(true);
      return;
    }
    onDismiss();
  }, [hasStartedRecording, onDismiss]);

  const confirmDiscardAction = useCallback(() => {
    setConfirmDiscard(false);
    onDismiss(); // unmount cleanup stops the recorder + revokes the URL
  }, [onDismiss]);

  // iOS togglePlayback: play/pause the preview, restart when at the end.
  const togglePlayback = useCallback(() => {
    const audio = audioElRef.current;
    if (!output || !audio) return;
    if (isPlaying) {
      audio.pause();
      setIsPlaying(false);
    } else {
      if (
        Number.isFinite(audio.duration) &&
        audio.duration > 0 &&
        audio.currentTime >= audio.duration - 0.05
      ) {
        audio.currentTime = 0;
      }
      void audio
        .play()
        .then(() => setIsPlaying(true))
        .catch(() => setErrorMessage("Playback failed."));
    }
  }, [isPlaying, output]);

  // Revoke the object URL when the output is replaced or the sheet unmounts.
  useEffect(() => {
    return () => {
      if (output) URL.revokeObjectURL(output.url);
    };
  }, [output]);

  // iOS onDisappear: stop everything when the sheet goes away.
  useEffect(() => {
    disposedRef.current = false;
    return () => {
      disposedRef.current = true;
      if (timerRef.current !== null) {
        window.clearInterval(timerRef.current);
        timerRef.current = null;
      }
      const recorder = recorderRef.current;
      if (recorder && recorder.state !== "inactive") recorder.stop();
      stopAudioResources();
    };
  }, [stopAudioResources]);

  const statusText =
    status === "recording"
      ? `Recording. Stops at ${limitLabel}.`
      : status === "finished"
        ? "Ready to attach."
        : `Tap the microphone to start. Limit ${limitLabel}.`;

  const progressPct =
    previewDuration > 0 ? Math.min(100, (playbackTime / previewDuration) * 100) : 0;

  return (
    <div className="voice-sheet-backdrop" role="presentation">
      <div className="voice-sheet" role="dialog" aria-modal="true" aria-label="Voice note">
        <div className="voice-sheet-title">Voice Note</div>

        <button
          type="button"
          className={`voice-record-button ${
            status === "recording" ? "voice-record-button-recording" : ""
          }`}
          aria-label={status === "recording" ? "Stop recording" : "Start recording"}
          onClick={toggleRecording}
        >
          {status === "recording" ? (
            <Square size={38} fill="currentColor" />
          ) : (
            <Mic size={38} fill="currentColor" />
          )}
        </button>

        <div
          className={`voice-waveform ${status === "recording" ? "voice-waveform-live" : ""}`}
          aria-hidden="true"
        >
          {samples.map((level, index) => {
            const recency = status === "recording" ? (index + 1) / samples.length : 0;
            const isLatestBar = status === "recording" && index === samples.length - 1;
            const opacity = isLatestBar
              ? 1
              : status === "recording"
                ? 0.28 + recency * 0.62
                : 0.42;
            return (
              <div
                key={index}
                className="voice-waveform-bar"
                style={{
                  height: `${Math.max(4, Math.round(level * 100))}%`,
                  opacity,
                }}
              />
            );
          })}
        </div>

        <div className="voice-duration">{formatVoiceDuration(elapsed)}</div>
        <div
          className={`voice-status ${
            status === "recording"
              ? "voice-status-recording"
              : status === "finished"
                ? "voice-status-ready"
                : ""
          }`}
        >
          {statusText}
        </div>

        {status === "finished" && output ? (
          <div className="voice-preview">
            <button
              type="button"
              className="voice-preview-button"
              aria-label={isPlaying ? "Pause preview" : "Play preview"}
              onClick={togglePlayback}
            >
              {isPlaying ? <Pause size={16} fill="currentColor" /> : <Play size={16} fill="currentColor" />}
            </button>
            <div className="voice-preview-meta">
              <div className="voice-preview-top">
                <span className="voice-preview-label">Preview</span>
                <span className="voice-preview-time">
                  {formatVoiceDuration(playbackTime)} / {formatVoiceDuration(elapsed)}
                </span>
              </div>
              <div className="voice-progress">
                <div className="voice-progress-fill" style={{ width: `${progressPct}%` }} />
              </div>
            </div>
          </div>
        ) : null}

        {errorMessage ? <div className="voice-error">{errorMessage}</div> : null}

        <div className="voice-actions">
          <button
            type="button"
            className={`voice-action voice-action-secondary ${
              hasStartedRecording ? "voice-action-destructive" : ""
            }`}
            onClick={requestDiscard}
          >
            {hasStartedRecording ? <Trash2 size={15} /> : <X size={15} />}
            {hasStartedRecording ? "Discard" : "Close"}
          </button>
          <button
            type="button"
            className="voice-action voice-action-primary"
            disabled={!canSave}
            onClick={save}
          >
            <Check size={15} />
            Save
          </button>
        </div>

        {output ? (
          <audio
            ref={audioElRef}
            className="voice-note-audio"
            src={output.url}
            preload="auto"
            onLoadedMetadata={(event) => setPreviewDuration(event.currentTarget.duration)}
            onTimeUpdate={(event) => setPlaybackTime(event.currentTarget.currentTime)}
            onEnded={() => {
              setPlaybackTime(0);
              setIsPlaying(false);
            }}
          />
        ) : null}

        {confirmDiscard ? (
          <div className="voice-confirm" role="alertdialog" aria-label="Discard voice note">
            <div className="voice-confirm-title">Discard voice note?</div>
            <div className="voice-confirm-message">This will delete the current voice note.</div>
            <div className="voice-confirm-actions">
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setConfirmDiscard(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="btn voice-confirm-destructive"
                onClick={confirmDiscardAction}
              >
                Discard Recording
              </button>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}
