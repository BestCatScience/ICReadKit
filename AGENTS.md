# ICReadKit agent instructions

- Read `README.md` and `docs/design.md` before changing either kit. The iOS kit
  (`Sources/ICReadKit`, Swift) and the Android kit (`android/icreadkit`, Java)
  share one design: change both together, keep their versions and demo-card
  identifiers equal, and keep the samples' accessibility identifiers equal so
  the shared Maestro flows in `maestro/ci` keep running on both.
- The kit sends only SELECT and READ BINARY. Never add a builder for VERIFY,
  CHANGE REFERENCE DATA, RESET RETRY COUNTER or any other command that presents
  or changes a PIN: a wrong PIN counts toward locking a real person's card.
  `CommandAPDU.Instruction.allowed` and its test fix this.
- Never log, persist, print or return certificate bytes, serial numbers,
  subjects or anything read from a card. `CertificateSummary` is the only thing
  that leaves the kit. Demo and test certificates are synthetic.
- Never crash the host app. Map every card, transport and Core NFC failure to a
  `CardReadError` case.
- Do not add third-party dependencies to either kit. The Android kit may
  depend on test libraries only.
- `project.yml` is the Xcode project authority; the generated project is not
  committed. Generate it with `scripts/generate-project.sh`.
- A public API change must pass `scripts/check-api.sh`. If a break is intended,
  update the baseline with `--update` and explain the break in the commit.
- Run the unit tests, the UI tests, `scripts/build-xcframework.sh`,
  `scripts/check-api.sh`, the Android unit tests and `:icreadkit:lintRelease`
  before claiming a change works. Real-card reading can
  only be checked on an iPhone; say so when it was not.
