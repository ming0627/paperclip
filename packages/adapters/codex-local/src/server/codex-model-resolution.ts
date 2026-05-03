import fs from "node:fs/promises";
import path from "node:path";
import { asString, parseObject } from "@paperclipai/adapter-utils/server-utils";
import {
  CODEX_LOCAL_DYNAMIC_MODEL,
  FALLBACK_CODEX_LOCAL_RESOLVED_MODEL,
} from "../index.js";
import { resolveSharedCodexHomeDir } from "./codex-home.js";

const DYNAMIC_MODEL_ALIASES = new Set([
  CODEX_LOCAL_DYNAMIC_MODEL,
  "auto",
  "codex-latest",
]);

function nonEmpty(value: string | undefined): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

export function isDynamicCodexModel(value: string | null | undefined): boolean {
  const normalized = nonEmpty(value ?? undefined);
  return Boolean(normalized && DYNAMIC_MODEL_ALIASES.has(normalized));
}

export function parseCodexConfigModel(contents: string): string | null {
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^model\s*=\s*(?:"([^"]+)"|'([^']+)'|([^#\s]+))/.exec(line);
    const value = match?.[1] ?? match?.[2] ?? match?.[3] ?? "";
    const normalized = value.trim();
    if (normalized && !isDynamicCodexModel(normalized)) return normalized;
  }
  return null;
}

async function readSharedCodexConfigModel(env: NodeJS.ProcessEnv): Promise<string | null> {
  const configPath = path.join(resolveSharedCodexHomeDir(env), "config.toml");
  const contents = await fs.readFile(configPath, "utf8").catch(() => "");
  return contents ? parseCodexConfigModel(contents) : null;
}

export async function resolveCodexRuntimeConfig(
  config: unknown,
  env: NodeJS.ProcessEnv = process.env,
): Promise<{ config: Record<string, unknown>; resolvedModel: string; note: string | null }> {
  const record = parseObject(config);
  const requestedModel = asString(record.model, "").trim();
  if (!isDynamicCodexModel(requestedModel)) {
    return { config: record, resolvedModel: requestedModel, note: null };
  }

  const overrideModel =
    nonEmpty(env.PAPERCLIP_CODEX_MODEL) ??
    nonEmpty(env.PAPERCLIP_LATEST_CODEX_MODEL);
  const sharedConfigModel = overrideModel ? null : await readSharedCodexConfigModel(env);
  const resolvedModel =
    overrideModel ??
    sharedConfigModel ??
    FALLBACK_CODEX_LOCAL_RESOLVED_MODEL;
  const source =
    overrideModel
      ? "PAPERCLIP_CODEX_MODEL"
      : sharedConfigModel
        ? `${resolveSharedCodexHomeDir(env)}/config.toml`
        : "adapter fallback";

  return {
    config: { ...record, model: resolvedModel },
    resolvedModel,
    note: `Resolved Codex model "${requestedModel}" to "${resolvedModel}" from ${source}.`,
  };
}
