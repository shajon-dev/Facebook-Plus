## Disclaimer & Terms of Use

- **Use at Your Own Risk:** Facebook Plus is an independent, third-party modification created solely for personal and educational purposes. By using this software, you acknowledge and agree that you are doing so entirely at your own risk.
- **Account Liability:** The developers and contributors of this project assume no responsibility or liability for any actions taken against your account (including temporary restrictions, lockouts, or permanent bans), data loss, or any other issues arising from the use of this tweak.
- **Trademark Notice:** "Facebook", "Meta", and associated trademarks, logos, and brand assets are the intellectual property of Meta Platforms, Inc. This project is in no way affiliated with, authorized, maintained, sponsored, or endorsed by Meta Platforms, Inc. or any of its affiliates.

## Account Safety

Facebook Plus changes how the official app behaves. Most features are local or read-only and carry little risk, but some do not, so a few precautions are worth taking:

- **Prefer a secondary account for the riskier features.** If an account matters to you, keep it on the safe defaults.
- **The Facebook Plus subscription unlock is the main risk.** It overrides Meta's paid-feature gate on the client only; Meta still verifies on its servers and can detect the mismatch. That is why it is off by default and kept behind a warning. The Story diamond and heart "super reactions" are the most visible example, since they are sent to other people. Leave this off on an account you care about.
- **Keep your signing certificate and provisioning profile private.** On a sideloaded build these identify you, so do not share them.
- **Do not publish or share an injected IPA.** It contains Facebook's own application, which is not yours to distribute, and sharing one risks takedowns. See [RELEASE-POLICY.md](.github/RELEASE-POLICY.md).
- **Keep the tweak updated.** A Facebook update can change a hooked class; the tweak degrades that one feature safely, but staying current avoids surprises.

## Reporting Security Vulnerabilities

We take the security and privacy of our users seriously. If you discover a security vulnerability within Facebook Plus itself (such as unintentional credential exposure, insecure storage, or memory leaks):

1. **Do not disclose it publicly:** Please do not open a public issue on GitHub.
2. **Contact Privately:** Report vulnerabilities directly via Telegram at [@SHAJON](https://t.me/SHAJON) with a brief description and proof-of-concept steps.
3. We will review the issue and release a patch as quickly as possible.

