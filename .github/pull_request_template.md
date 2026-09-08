<!-- Thanks for contributing. Nothing here is bureaucracy: each line is
     something that has actually broken before. -->

**What this changes, and why**

**Checklist**

- [ ] `swift test` passes
- [ ] `./scripts/build.sh` and `./scripts/make-app.sh` both succeed
- [ ] No new user-visible string is written inline — they go through
      `L10n.t("English", "한국어")`
- [ ] If detection changed, there is a fixture test for it in
      `Tests/VibeCheckTests/`
- [ ] If a README claim changed, the README changed with it

**If this touches detection**

Which signal did you change — hooks, transcript tail, or CPU? What did you
verify it against? Detection has been corrected several times; a note here saves
the next person the archaeology.
