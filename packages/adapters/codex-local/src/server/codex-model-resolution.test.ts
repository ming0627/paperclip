import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  parseCodexConfigModel,
  resolveCodexRuntimeConfig,
} from "./codex-model-resolution.js";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => fs.rm(dir, { recursive: true, force: true })));
});

async function makeCodexHome(configToml: string): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "paperclip-codex-home-"));
  tempDirs.push(dir);
  await fs.writeFile(path.join(dir, "config.toml"), configToml, "utf8");
  return dir;
}

describe("Codex dynamic model resolution", () => {
  it("parses the top-level Codex model from config.toml", () => {
    expect(parseCodexConfigModel('model = "gpt-5.5"\n')).toBe("gpt-5.5");
    expect(parseCodexConfigModel("# comment\nmodel = 'gpt-5.4'\n")).toBe("gpt-5.4");
  });

  it("resolves latest from PAPERCLIP_CODEX_MODEL first", async () => {
    const result = await resolveCodexRuntimeConfig(
      { model: "latest" },
      { PAPERCLIP_CODEX_MODEL: "gpt-5.6" },
    );

    expect(result.resolvedModel).toBe("gpt-5.6");
    expect(result.config.model).toBe("gpt-5.6");
    expect(result.note).toContain("PAPERCLIP_CODEX_MODEL");
  });

  it("resolves latest from the shared Codex config", async () => {
    const codexHome = await makeCodexHome('model = "gpt-5.5"\n');
    const result = await resolveCodexRuntimeConfig(
      { model: "latest", fastMode: true },
      { CODEX_HOME: codexHome },
    );

    expect(result.resolvedModel).toBe("gpt-5.5");
    expect(result.config).toMatchObject({ model: "gpt-5.5", fastMode: true });
    expect(result.note).toContain("config.toml");
  });
});
