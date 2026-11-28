// Reads the live deployment. Run with: LIVE=1 npm test
import { describe, expect, it } from "vitest";

import { deployment } from "../generated/deployment";
import { eventLog } from "../lib/events";
import { readLasna, readState } from "./state";

describe.runIf(process.env.LIVE)("live deployment", () => {
  it("reads the pool, the control and the curator sleeves", async () => {
    const s = await readState();
    expect(s.sleeves.length).toBeGreaterThanOrEqual(2);
    expect(s.sleeves[0].ranges.length).toBe(1); // the control's full-range position
    expect(s.sleeves[1].bonded).toBe(true);
    expect(s.sqrtPriceX96 > 0n).toBe(true);
    console.log({
      block: s.block,
      tick: s.tick,
      openTick: s.openTick,
      sleeves: s.sleeves.map((x) => ({ id: x.id, ranges: x.ranges.length, value: x.value, excess: x.score.excess })),
      keeper: s.keeperBalance,
    });
  }, 60_000);

  it("reads Reactive Lasna", async () => {
    const l = await readLasna();
    expect(l.keeper.toLowerCase()).toBe(deployment.unichain.keeper.toLowerCase());
    console.log(l);
  }, 60_000);

  it("loads every Zenith event", async () => {
    const events = await eventLog.update();
    const names = events.reduce<Record<string, number>>((m, e) => ({ ...m, [`${e.source}.${e.eventName}`]: (m[`${e.source}.${e.eventName}`] ?? 0) + 1 }), {});
    console.log(names);
    expect(names["keeper.Swept"]).toBeGreaterThan(0);
    expect(names["pool.ModifyLiquidity"]).toBeGreaterThan(0);
  }, 120_000);
});
