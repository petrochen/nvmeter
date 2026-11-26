# Security

NVMeter reads drive data through macOS APIs without elevated rights. The parts that change state are the Speed Test
(temporary files), the Volumes controls (unmount, mount, read-only) and the MCP server's tools that do the same.

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/petrochen/nvmeter/security/advisories/new), not in a public issue.
You will get an answer within a week. Fixes go into the next release; the latest release is the only supported one.
