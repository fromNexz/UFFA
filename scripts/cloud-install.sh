#!/usr/bin/env bash
set -euo pipefail
cd /workspace/UFFA
export npm_config_cache=/workspace/.cache/npm
export XDG_CACHE_HOME=/workspace/.cache
export XDG_CONFIG_HOME=/workspace/.config
export XDG_DATA_HOME=/workspace/.local/share
mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" /workspace/tools
npm ci --ignore-scripts
pwsh_dir=/workspace/tools/powershell-7.4.13
if [ ! -x "$pwsh_dir/pwsh" ]; then
  setup_tmp=$(mktemp -d /tmp/uffa-cloud-XXXXXX)
  trap 'rm -rf "$setup_tmp"' EXIT
  curl -fsSL --retry 2 https://github.com/PowerShell/PowerShell/releases/download/v7.4.13/hashes.sha256 -o "$setup_tmp/hashes.sha256"
  curl -fsSL --retry 2 https://github.com/PowerShell/PowerShell/releases/download/v7.4.13/powershell-7.4.13-linux-x64.tar.gz -o "$setup_tmp/powershell.tar.gz"
  python - "$setup_tmp" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); raw=(root/'hashes.sha256').read_bytes()
checks=raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig')
expected=next(x.split()[0] for x in checks.splitlines() if x.strip().endswith('powershell-7.4.13-linux-x64.tar.gz'))
assert hashlib.sha256((root/'powershell.tar.gz').read_bytes()).hexdigest().lower()==expected.lower(), 'PowerShell SHA256 mismatch'
PY
  mkdir -p "$pwsh_dir"
  tar -xzf "$setup_tmp/powershell.tar.gz" -C "$pwsh_dir"
  chmod u+x "$pwsh_dir/pwsh"
fi
if [ ! -f /workspace/tools/net472/build/.NETFramework/v4.7.2/mscorlib.dll ]; then
  refs_tmp=$(mktemp -d /tmp/uffa-refs-XXXXXX)
  curl -fsSL --retry 2 https://api.nuget.org/v3-flatcontainer/microsoft.netframework.referenceassemblies.net472/1.0.3/microsoft.netframework.referenceassemblies.net472.1.0.3.nupkg -o "$refs_tmp/net472.nupkg"
  mkdir -p /workspace/tools/net472
  unzip -q -o "$refs_tmp/net472.nupkg" -d /workspace/tools/net472
  rm -rf "$refs_tmp"
fi
npm test
npm run typecheck
"$pwsh_dir/pwsh" -NoProfile -File tests/Run-AgentTests.ps1
"$pwsh_dir/pwsh" -NoProfile -File tests/Installer.Tests.ps1
"$pwsh_dir/pwsh" -NoProfile -File tests/WebInstall.Tests.ps1
"$pwsh_dir/pwsh" -NoProfile -File tests/Compile-Framework.ps1 -ReferenceDirectory /workspace/tools/net472/build/.NETFramework/v4.7.2
