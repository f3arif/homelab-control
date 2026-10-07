# AFZ Movies & TV R30: phone-first source ordering

Status: staged canonical follow-up to R29. This revision changes **phone playback/source presentation only**.

## Problem reproduced

On a phone, AFZ movie rows can arrive in backend order:

1. AFZ Play Best (often 2160p)
2. Auto-save
3. AFZ Auto 4K
4. AFZ Auto 1080p
5. AFZ Auto TV
6. AFZ Auto Mobile
7. AFZ Auto Data Saver
8. AFZ Phone 1080p TorBox

That is correct provider data but wrong phone UX. R29 intentionally anchored the phone recommendation *after* `AFZ Play Best`, and an explicit `AFZ Phone 1080p`/series `AFZ TV Mobile 1080p` row can also be filtered out of the phone recommendation if the AFZ action classifier recognizes its label.

## R30 behavior

On **Phone** only:

- A concrete fixed 1080p phone source is featured first when available.
- `AFZ Phone 1080p …` and `AFZ TV Mobile 1080p …` are valid phone candidates even when their AFZ-prefixed labels are recognized by quick-action parsing.
- The remaining AFZ source rows are stable-sorted:
  1. explicit phone/mobile 1080p
  2. AFZ Auto Mobile
  3. AFZ Auto Data Saver
  4. AFZ Auto 1080p
  5. other 1080p
  6. AFZ Play Best
  7. Auto-save / other controls and sources
  8. AFZ Auto TV
  9. AFZ Auto 4K
- The featured concrete source is not duplicated later in the list.
- TV, tablet, computer, and download-only picker behavior remain unchanged.

## Safety / scope

This does not change source resolution, TorBox provider configuration, Real-Debrid state, playback resolution rules, or the download engine. It is presentation/ranking only.

Apply `phone-first-r30.patch` on top of the preserved R29/R31 phone-streaming source. The patch is deliberately narrow so later universal-row fixes can carry it cleanly.
