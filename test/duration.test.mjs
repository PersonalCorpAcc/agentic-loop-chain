import assert from "node:assert/strict";
import { test } from "node:test";

import { format, parse } from "../src/duration.mjs";

test("parses each unit", () => {
  assert.equal(parse("30s"), 30_000);
  assert.equal(parse("5m"), 300_000);
  assert.equal(parse("2h"), 7_200_000);
  assert.equal(parse("1d"), 86_400_000);
});

test("refuses anything else", () => {
  assert.equal(parse("5"), null);
  assert.equal(parse("0m"), null);
  assert.equal(parse("5 m"), null);
  assert.equal(parse("1w"), null);
});

test("formats in the largest unit that divides exactly", () => {
  assert.equal(format(300_000), "5m");
  assert.equal(format(90_000), "90s");
  assert.equal(format(86_400_000), "1d");
});

test("round-trips everything it parses", () => {
  for (const value of ["45s", "5m", "90m", "2h", "3d"]) assert.equal(format(parse(value)), value);
});
