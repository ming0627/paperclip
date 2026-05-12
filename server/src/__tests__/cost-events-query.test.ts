import { describe, expect, it } from "vitest";
import { parseCostEventListQuery } from "../routes/costs.js";

describe("parseCostEventListQuery", () => {
  it("parses raw cost event filters and caps default pagination", () => {
    expect(
      parseCostEventListQuery({
        agentId: "agent-1",
        model: "gpt-5",
        since: "2026-05-12T00:00:00.000Z",
        limit: "5",
        cursor: "opaque-cursor",
      }),
    ).toEqual({
      agentId: "agent-1",
      model: "gpt-5",
      since: new Date("2026-05-12T00:00:00.000Z"),
      limit: 5,
      cursor: "opaque-cursor",
    });

    expect(parseCostEventListQuery({ limit: "5000" }).limit).toBe(1000);
    expect(parseCostEventListQuery({}).limit).toBe(100);
  });

  it("rejects invalid raw cost event query params", () => {
    expect(() => parseCostEventListQuery({ since: "not-a-date" })).toThrow(/invalid 'since' date/i);
    expect(() => parseCostEventListQuery({ limit: "0" })).toThrow(/invalid 'limit'/i);
  });
});
