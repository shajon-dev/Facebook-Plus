# Release policy

**No published release may carry an `.ipa` file. Ever.**

Draft releases are a different thing and are fine. The **Build Facebook Plus
(.ipa)** workflow writes its output to a draft release on whoever's fork ran it,
and a draft is visible only to that person. That is how someone gets their own
build back, from their own copy of Facebook. The line is publishing.

## Why

An injected IPA is Facebook's own application with our tweak added to it. The
code in this repository is ours and is GPLv3. The application inside that IPA is
not, and we have no right to distribute it. Publishing one also puts the
repository and the account that owns it at risk: it is the most common reason iOS
tweak projects are taken down, and it has happened to well known ones more than
once, the second time for re-landing nothing more than a download link to such a
release.

The project does not need it. The `.deb` packages contain only our own code, and
anyone who sideloads can build their own IPA in about fifteen minutes.

## What a published release may contain

| Allowed | Not allowed |
|---|---|
| `Facebook-Plus-v<version>-rootless.deb` | any `.ipa` |
| `Facebook-Plus-v<version>-rootfull.deb` | any archive containing an `.ipa` |
| `FBPNotifyBridge.dylib` | a link in the release notes to an `.ipa` hosted anywhere |
| release notes, checksums | |

## How it is enforced

1. **`.gitignore`** refuses `*.ipa` anywhere in the tree, so one cannot be
   committed in the first place.
2. **`no-ipa-in-releases.yml`** runs when a release is published or edited, once
   a day, and on demand. It walks every **published** release, deletes any `.ipa`
   asset, and fails the run so the deletion is visible. It never touches a draft.
3. **This file**, so nobody has to rediscover the reason.

The one path the automation cannot stop is a human attaching an IPA by hand and
the guard removing it a moment later. That is what the guard is for, but do not
rely on it: the asset exists publicly until the run finishes.

## If you are publishing a release

Upload the `.deb` files and the bridge dylib. Point sideloaders at
**Actions → Build Facebook Plus (.ipa)**, which gives them a draft release on
their own fork, built from their own copy. Do not paste a link to an IPA hosted
elsewhere either; the objection is to distributing the application, not to the
hosting.
