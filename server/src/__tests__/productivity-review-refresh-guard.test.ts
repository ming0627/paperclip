import { describe, expect, it } from "vitest";
import {
  DEFAULT_PRODUCTIVITY_REVIEW_MAX_REFRESH_ATTEMPTS,
  shouldCapProductivityReviewRefresh,
} from "../services/productivity-review.ts";

describe("productivity review refresh guard", () => {
  it("allows refreshes below the max attempt count", () => {
    expect(
      shouldCapProductivityReviewRefresh({
        updateAttempts: DEFAULT_PRODUCTIVITY_REVIEW_MAX_REFRESH_ATTEMPTS - 1,
        capAlerts: 0,
      }),
    ).toEqual({ capped: false, shouldAlert: false });
  });

  it("alerts exactly once after the max attempt count", () => {
    expect(
      shouldCapProductivityReviewRefresh({
        updateAttempts: DEFAULT_PRODUCTIVITY_REVIEW_MAX_REFRESH_ATTEMPTS,
        capAlerts: 0,
      }),
    ).toEqual({ capped: true, shouldAlert: true });

    expect(
      shouldCapProductivityReviewRefresh({
        updateAttempts: DEFAULT_PRODUCTIVITY_REVIEW_MAX_REFRESH_ATTEMPTS + 12,
        capAlerts: 1,
      }),
    ).toEqual({ capped: true, shouldAlert: false });
  });
});
