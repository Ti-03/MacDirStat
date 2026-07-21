# Security Policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 1.1.x   | Yes       |
| < 1.1   | No        |

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/Ti-03/MacDirStat/security/advisories/new)
("Report a vulnerability" on the repo's Security tab). That keeps the report
confidential while a fix is prepared.

What to include:

- What the issue is and where (file, function, or behavior).
- Steps to reproduce, or a proof of concept.
- What an attacker gains (impact).

What to expect:

- An acknowledgment within 7 days.
- A fix or a status update within 30 days for confirmed issues.
- Credit in the release notes if you want it.

MacDirStat is a local, on-device app: it never sends data off the machine, so
most issues in scope are local ones (unsafe file operations, privilege
mistakes, malicious folder contents crashing or confusing the scanner).
