import { describe, expect, it } from "vitest";
import { compactRunLogChunk, deriveHeartbeatRunFailureMessage } from "../services/heartbeat.js";

describe("compactRunLogChunk", () => {
  it("redacts inline base64 image data from structured log chunks", () => {
    const base64 = "A".repeat(4096);
    const chunk = `{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","data":"${base64}"}}]}}\n`;

    const compacted = compactRunLogChunk(chunk);

    expect(compacted).not.toContain(base64);
    expect(compacted).toContain("[omitted base64 image data: 4096 chars]");
  });

  it("truncates oversized chunks after sanitizing them", () => {
    const chunk = `${"x".repeat(90_000)}tail`;

    const compacted = compactRunLogChunk(chunk, 16_384);

    expect(compacted.length).toBeLessThan(chunk.length);
    expect(compacted).toContain("[paperclip truncated run log chunk:");
    expect(compacted.endsWith("tail")).toBe(true);
  });
});

describe("deriveHeartbeatRunFailureMessage", () => {
  it("prefers the last stderr line for failed runs", () => {
    expect(
      deriveHeartbeatRunFailureMessage({
        exitCode: 1,
        stderrExcerpt: "warning\nfatal: provider quota exhausted\n",
        stdoutExcerpt: "{\"type\":\"turn.failed\",\"error\":{\"message\":\"usage limit\"}}\n",
        adapterErrorMessage: "Adapter failed",
      }),
    ).toBe("fatal: provider quota exhausted");
  });

  it("uses structured stdout errors when stderr is empty", () => {
    expect(
      deriveHeartbeatRunFailureMessage({
        exitCode: 1,
        stderrExcerpt: "",
        stdoutExcerpt: "{\"type\":\"turn.failed\",\"error\":{\"message\":\"You've hit your usage limit\"}}\n",
        adapterErrorMessage: "Adapter failed",
      }),
    ).toBe("You've hit your usage limit");
  });

  it("falls back to the adapter process exit reason and truncates to 1KB", () => {
    const message = `Codex exited with code 1: ${"x".repeat(2_000)}`;
    const derived = deriveHeartbeatRunFailureMessage({
      exitCode: 1,
      stderrExcerpt: "",
      stdoutExcerpt: "",
      adapterErrorMessage: message,
    });

    expect(derived).toHaveLength(1024);
    expect(derived).toContain("Codex exited with code 1");
  });
});
