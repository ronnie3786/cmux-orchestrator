import { describe, expect, it } from "vitest";
import {
  HTTPS_REQUIRED_ERROR,
  OnboardingView,
  prefillServerUrl,
  URL_REQUIRED_ERROR,
  validateServerUrl,
} from "./OnboardingView";

describe("validateServerUrl (iOS ServerConfiguration URL policy)", () => {
  it("accepts https anywhere", () => {
    expect(validateServerUrl("https://your-mac.tailnet.ts.net")).toBeNull();
    expect(validateServerUrl("https://mac:9092")).toBeNull();
  });

  it("accepts http only for loopback hosts", () => {
    expect(validateServerUrl("http://localhost:9092")).toBeNull();
    expect(validateServerUrl("http://127.0.0.1:9092")).toBeNull();
    expect(validateServerUrl("http://[::1]:9092")).toBeNull();
  });

  it("rejects http on non-loopback hosts with the byte-exact error", () => {
    expect(HTTPS_REQUIRED_ERROR).toBe("Use HTTPS, or HTTP only when connecting to localhost.");
    expect(validateServerUrl("http://your-mac.tailnet.ts.net")).toBe(HTTPS_REQUIRED_ERROR);
    expect(validateServerUrl("http://10.0.0.4:9092")).toBe(HTTPS_REQUIRED_ERROR);
  });

  it("rejects empty and unparseable URLs", () => {
    expect(validateServerUrl("")).toBe(URL_REQUIRED_ERROR);
    expect(validateServerUrl("   ")).toBe(URL_REQUIRED_ERROR);
    expect(validateServerUrl("not a url")).toBe(HTTPS_REQUIRED_ERROR);
  });
});

describe("prefillServerUrl", () => {
  it("falls back to the loopback default outside a browser", () => {
    // Vitest node environment: no window, no localStorage — the prefill is
    // the default server the client would target anyway.
    expect(prefillServerUrl()).toBe("http://127.0.0.1:9092");
  });
});

describe("OnboardingView module", () => {
  it("exports the component", () => {
    expect(typeof OnboardingView).toBe("function");
  });
});
