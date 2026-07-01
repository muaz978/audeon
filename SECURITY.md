# Security Policy

## Supported versions

Audeon is maintained by a single developer. Only the latest release on the
[Releases page](https://github.com/muaz978/audeon/releases) receives security
fixes. Please update to the latest version before reporting an issue, and
confirm the problem still reproduces there.

## Reporting a vulnerability

Please do not open a public GitHub issue for a security vulnerability.

Instead, use GitHub's private vulnerability reporting for this repository:

1. Go to the [Security tab](https://github.com/muaz978/audeon/security).
2. Click **Report a vulnerability**.
3. Describe the issue, including steps to reproduce and the affected version.

This opens a private advisory that only the maintainer can see until a fix is
ready, so the issue is not disclosed before it can be patched.

## Scope

Audeon reads audio devices and, on macOS 14.2 and later, captures application
audio using Core Audio process taps. Reports involving these permissions,
the private aggregate audio devices Audeon creates, or how audio data is
routed and stored are especially welcome.

## Response

This is a solo, unpaid open source project. There is no guaranteed response
time, but valid reports are taken seriously and fixed as soon as possible.
