## 1. Implement week unit

- [ ] 1.1 Add `w` (604,800,000 ms) to the `UNITS` table in `src/duration.mjs`, ordered so `format` still prefers the largest unit that divides a value exactly
- [ ] 1.2 Update the `parse` regex character class to accept `w`

## 2. Tests

- [ ] 2.1 Add a test asserting `parse("2w")` returns `1209600000`
- [ ] 2.2 Add a test asserting `format(1209600000)` returns `"2w"`
- [ ] 2.3 Add a test asserting `format(parse("14d"))` returns `"2w"` and `format(parse("10d"))` still returns `"10d"`
- [ ] 2.4 Confirm the existing tests in `test/duration.test.mjs` still pass
