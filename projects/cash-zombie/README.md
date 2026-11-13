# Cash Zombie

**Android tip, income, and shift tracker · Flutter · Active development**

Cash Zombie is a zombie-branded Android app for tracking hourly pay, cash/card tips, and work shifts. The project evolved from the earlier **Tipsi** app into a separately branded Flutter application.

## What has been developed

- Clock In and Clock Out shift tracking, with calculated worked duration.
- Editable shift start and end times.
- Multiple shifts on one day, sorted chronologically; editing a shift reorders the day's list.
- Hourly earnings and cash/card tip tracking.
- Income history, graphs, and calendar-related views.
- Local SQLite-backed data persistence.
- Mobile interface and selected tablet-responsive layouts.
- Backup/export-related functionality from the preserved application baseline.

These features describe the documented project; not every individual feature was independently retested in the latest checkpoint.

## Verified checkpoints

| Area | Evidence-based status |
| --- | --- |
| Older protected source | **v0.2.3 tablet-validated recovery baseline**, preserved separately |
| Last confirmed Google Play installation | **v0.2.4, versionCode 6**, deployed through **Internal testing** and received on the owner's phone |
| Later working-copy version | **v0.2.5+7**, verified in development on August 29, 2026 |
| v0.2.5+7 code checks | `flutter analyze` clean; **18 Flutter tests passed** |
| Android debug test | Earlier debug APK successfully built and opened; navigation changes had also been tested on a Pixel 8 emulator |
| v0.2.5+7 Play release | **Not verified**; don't confuse a passing development build with an uploaded or distributed AAB |
| Public Google Play availability | **Not claimed** |

The application's last documented implementation improvements included shift pause/resume and History navigation work. Their earlier independent validation checkpoints are retained; the latest v0.2.5+7 verification was a clean analyzer/test run. No claim is made that every earlier experimental branch was promoted.

## Planned improvements

Responsive Calendar/Settings refinements, shift pause/resume edge cases, and additional release testing have been part of the roadmap. They must be checked against the current working source before being proposed or reimplemented.

## Source, downloads, and privacy

**This folder is a portfolio showcase, not a public source or installer release.** The protected source and Android signing assets have not been uploaded here. The current Play testing state should be checked in the owner's Play Console before providing a tester or public Play link.

Do not upload real work/earnings data, database backups, signing keystores, signing properties, passwords, or other private information.

## Credits

**KushZombie:** Concept, branding/design direction, testing, and acceptance decisions. Development used AI-assisted Flutter implementation and iterative testing.

[Return to the KushZombie portfolio](../../README.md)

*Status evidence last checked against August 2026 development notes; public showcase added November 2026.*
