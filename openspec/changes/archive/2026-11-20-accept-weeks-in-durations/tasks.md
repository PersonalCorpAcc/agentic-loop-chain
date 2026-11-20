## 1. Implement week unit

- [x] 1.1 Add `w` (604,800,000 ms) to the `UNITS` table in `src/duration.mjs`, ordered so `format` still prefers the largest unit that divides a value exactly
- [x] 1.2 Update the `parse` regex character class to accept `w`

## 2. Tests

- [x] 2.1 Add a test asserting `parse("2w")` returns `1209600000`
- [x] 2.2 Add a test asserting `format(1209600000)` returns `"2w"`
- [x] 2.3 Add a test asserting `format(parse("14d"))` returns `"2w"` and `format(parse("10d"))` still returns `"10d"`
- [x] 2.4 Confirm the existing tests in `test/duration.test.mjs` still pass
