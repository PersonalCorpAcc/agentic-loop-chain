# loop-chain

The branch-chain proving ground for the agentic loop.

A change is implemented against `dev`, and once it has landed there the loop promotes that
change -- its own commits, found by patch-id, and nothing else -- to `test`, and after the
soak to `main`, where its issue closes. Each hop is a pull request, and `main` is a person's
to land.
