# Installs a local Windows ARM64 build of Herdr: herdr-core into
# %LOCALAPPDATA%\Programs\herdr-core (where the app looks for it) and the app
# into %LOCALAPPDATA%\Programs\herdr-app, both on your user PATH, Herdr in the
# Start menu. The same layout install.ps1 and the core's installer produce.
#
# -From is a folder holding the two artifacts of the windows-arm64 workflow,
# as GitHub downloads them (each wrapped in its own zip):
#   herdr-core-windows-aarch64.zip   herdr-app-windows-aarch64.zip
#
#   powershell -ExecutionPolicy Bypass -File install-arm64.ps1 -From $HOME\Downloads
param([Parameter(Mandatory)][string]$From)
$ErrorActionPreference = "Stop"
function Fail($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -ne "ARM64") { Fail "this is the ARM64 build; this machine is $arch" }
$tar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $tar)) { Fail "needs Windows' tar (Windows 10 1803 or newer)" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "herdr-arm64-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# The artifact GitHub serves, unwrapped to the build's own archive.
function Unwrap($name, $inner) {
    $outer = Get-ChildItem -Path $From -Filter "$name*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $outer) { Fail "no $name*.zip in $From" }
    $dest = Join-Path $tmp $name
    Expand-Archive -Force $outer.FullName $dest
    $file = Join-Path $dest $inner
    if (-not (Test-Path $file)) { Fail "$($outer.Name) holds no $inner" }
    $file
}

function AddToPath($dir) {
    # The raw user PATH, so %VARIABLES% in it stay unexpanded and keep their type.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    $raw = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $listed = $raw -split ";" | Where-Object { $_.Trim().TrimEnd("\") -ieq $dir.TrimEnd("\") }
    if (-not $listed) {
        $kind = if ($key.GetValueNames() -contains "Path") { $key.GetValueKind("Path") } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $key.SetValue("Path", $(if ($raw) { "$($raw.TrimEnd(';'));$dir" } else { $dir }), $kind)
        Write-Host "Added $dir to your PATH."
    }
    $key.Close()
    if (($env:Path -split ";") -notcontains $dir) { $env:Path += ";$dir" }
}

try {
    # --- herdr-core ---
    $coreZip = Unwrap "herdr-core-windows-aarch64" "herdr-core-windows-aarch64.zip"
    New-Item -ItemType Directory -Force "$tmp\hc" | Out-Null
    & $tar -xf $coreZip -C "$tmp\hc"
    if ($LASTEXITCODE -or -not (Test-Path "$tmp\hc\conpty\arm64\OpenConsole.exe")) { Fail "the core archive is incomplete" }
    $version = (& "$tmp\hc\herdr-core.exe" --version) -replace "^hc ", ""
    if ($LASTEXITCODE) { Fail "the built herdr-core does not run on this machine" }

    $coreDir = Join-Path $env:LOCALAPPDATA "Programs\herdr-core"
    New-Item -ItemType Directory -Force $coreDir | Out-Null
    $coreExe = Join-Path $coreDir "herdr-core.exe"
    if (Test-Path $coreExe) {
        # Swapped the planned way, so its terminals keep running.
        & $coreExe update --from "$tmp\hc\herdr-core.exe" | Out-Null
        if ($LASTEXITCODE) { Fail "updating $coreExe failed (see above)" }
        Write-Host "herdr-core updated to $version."
    } else {
        Copy-Item -Recurse -Force "$tmp\hc\herdr-core.exe", "$tmp\hc\conpty" $coreDir
        Write-Host "herdr-core $version installed into $coreDir."
    }
    Copy-Item -Recurse -Force "$tmp\hc\THIRD-PARTY-NOTICES", "$tmp\hc\LICENSE" $coreDir -ErrorAction SilentlyContinue
    if (-not (Get-Command hc -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $coreDir "hc.exe"))) {
        New-Item -ItemType HardLink -Path (Join-Path $coreDir "hc.exe") -Target $coreExe | Out-Null
    }
    AddToPath $coreDir

    # --- herdr-app ---
    $appTar = Unwrap "herdr-app-windows-aarch64" "herdr-app-windows-aarch64.tar.gz"
    & $tar -xzf $appTar -C $tmp
    if ($LASTEXITCODE -or -not (Test-Path "$tmp\herdr-app\herdr-app.exe")) { Fail "the app archive is incomplete" }
    $appVersion = & "$tmp\herdr-app\herdr-app.exe" --version
    if ($LASTEXITCODE) { Fail "the built herdr-app does not run on this machine" }

    $appDir = Join-Path $env:LOCALAPPDATA "Programs\herdr-app"
    New-Item -ItemType Directory -Force (Split-Path $appDir) | Out-Null
    if (Test-Path "$appDir.old") { Remove-Item -Recurse -Force "$appDir.old" }
    if (Test-Path $appDir) { Rename-Item $appDir "$appDir.old" }
    Move-Item "$tmp\herdr-app" $appDir
    if (Test-Path "$appDir.old") { Remove-Item -Recurse -Force "$appDir.old" -ErrorAction SilentlyContinue }
    $exe = Join-Path $appDir "herdr-app.exe"
    $menu = Join-Path ([Environment]::GetFolderPath("Programs")) "Herdr.lnk"
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($menu)
    $link.TargetPath = $exe
    $link.WorkingDirectory = $env:USERPROFILE
    $link.Save()
    AddToPath $appDir
    Write-Host "$appVersion installed into $appDir. Herdr is in the Start menu; open a new terminal for the PATH."
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
