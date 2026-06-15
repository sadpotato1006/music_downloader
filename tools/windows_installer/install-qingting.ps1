param(
  [string]$Payload = "QingTingPayload.zip"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Join-Chars([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

$AppName = Join-Chars @(0x9752, 0x542C)
$AppId = "QingTing"
$Version = "1.1.0"
$Publisher = "Pobb"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PayloadPath = Join-Path $ScriptDir $Payload
$DefaultInstallDir = Join-Path $env:LOCALAPPDATA "Programs\QingTing"

if (!(Test-Path -LiteralPath $PayloadPath)) {
  [System.Windows.Forms.MessageBox]::Show(
    "Payload not found: $PayloadPath",
    "QingTing Setup",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}

$state = @{
  Page = 0
  InstallDir = $DefaultInstallDir
  CreateDesktopShortcut = $true
  CreateStartMenuShortcut = $true
  RunAfterInstall = $true
  InstalledExe = $null
}

function New-Label($Text, $X, $Y, $Width, $Height, $FontSize = 10, $Bold = $false) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, $Height)
  $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
  $label.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", [float]$FontSize, $style)
  return $label
}

function Ensure-Parent($Path) {
  $parent = Split-Path -Parent $Path
  if ($parent -and !(Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Get-DirectorySizeKb($Path) {
  if (!(Test-Path -LiteralPath $Path)) { return 0 }
  $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $bytes) { return 0 }
  return [int][Math]::Ceiling($bytes / 1KB)
}

function Write-Uninstaller($InstallDir, $ExePath) {
  $uninstallPs1 = Join-Path $InstallDir "uninstall-qingting.ps1"
  $uninstallBat = Join-Path $InstallDir "uninstall-qingting.bat"
  $script = @'
param(
  [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
function Join-Chars([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

$AppName = Join-Chars @(0x9752, 0x542C)
$InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "$AppName.lnk"
$StartMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName"
$UninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\QingTing"

Remove-Item -LiteralPath $DesktopShortcut -Force
Remove-Item -LiteralPath $StartMenuDir -Recurse -Force
Remove-Item -LiteralPath $UninstallKey -Recurse -Force

if (-not $Quiet) {
  Add-Type -AssemblyName System.Windows.Forms
  [System.Windows.Forms.MessageBox]::Show(
    "$AppName has been removed.",
    "QingTing Uninstall",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  ) | Out-Null
}

$escaped = $InstallDir.Replace('"', '\"')
Start-Process -FilePath "cmd.exe" -ArgumentList "/c ping 127.0.0.1 -n 2 >nul & rmdir /s /q `"$escaped`"" -WindowStyle Hidden
'@
  [System.IO.File]::WriteAllText($uninstallPs1, $script, [System.Text.UTF8Encoding]::new($false))

  $bat = @"
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-qingting.ps1" %*
"@
  [System.IO.File]::WriteAllText($uninstallBat, $bat, [System.Text.ASCIIEncoding]::new())
  return $uninstallBat
}

function Install-App($StatusLabel, $ProgressBar) {
  $InstallDir = $state.InstallDir.Trim()
  if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw "Install directory cannot be empty."
  }

  $StatusLabel.Text = "Preparing install directory..."
  $ProgressBar.Value = 10
  [System.Windows.Forms.Application]::DoEvents()

  if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

  $StatusLabel.Text = "Copying application files..."
  $ProgressBar.Value = 35
  [System.Windows.Forms.Application]::DoEvents()

  Expand-Archive -LiteralPath $PayloadPath -DestinationPath $InstallDir -Force
  $ExePath = Join-Path $InstallDir "qingting.exe"
  if (!(Test-Path -LiteralPath $ExePath)) {
    throw "qingting.exe was not found after extraction."
  }
  $state.InstalledExe = $ExePath

  $StatusLabel.Text = "Creating shortcuts..."
  $ProgressBar.Value = 65
  [System.Windows.Forms.Application]::DoEvents()

  $shell = New-Object -ComObject WScript.Shell
  if ($state.CreateDesktopShortcut) {
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "$AppName.lnk"
    $shortcut = $shell.CreateShortcut($desktopShortcut)
    $shortcut.TargetPath = $ExePath
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation = "$ExePath,0"
    $shortcut.Description = "QingTing music downloader"
    $shortcut.Save()
  }

  if ($state.CreateStartMenuShortcut) {
    $startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName"
    New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null
    $startMenuShortcut = Join-Path $startMenuDir "$AppName.lnk"
    $shortcut = $shell.CreateShortcut($startMenuShortcut)
    $shortcut.TargetPath = $ExePath
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation = "$ExePath,0"
    $shortcut.Description = "QingTing music downloader"
    $shortcut.Save()

    $uninstallShortcut = Join-Path $startMenuDir "Uninstall QingTing.lnk"
    $shortcut = $shell.CreateShortcut($uninstallShortcut)
    $shortcut.TargetPath = Join-Path $InstallDir "uninstall-qingting.bat"
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Description = "Uninstall QingTing"
    $shortcut.Save()
  }

  $StatusLabel.Text = "Registering uninstaller..."
  $ProgressBar.Value = 85
  [System.Windows.Forms.Application]::DoEvents()

  $uninstallBat = Write-Uninstaller -InstallDir $InstallDir -ExePath $ExePath
  $uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppId"
  New-Item -Path $uninstallKey -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "DisplayName" -Value $AppName -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "DisplayVersion" -Value $Version -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "Publisher" -Value $Publisher -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "InstallLocation" -Value $InstallDir -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "DisplayIcon" -Value "$ExePath,0" -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "UninstallString" -Value "`"$uninstallBat`"" -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "QuietUninstallString" -Value "`"$uninstallBat`" /quiet" -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $uninstallKey -Name "EstimatedSize" -Value (Get-DirectorySizeKb $InstallDir) -PropertyType DWord -Force | Out-Null

  $StatusLabel.Text = "Install complete."
  $ProgressBar.Value = 100
  [System.Windows.Forms.Application]::DoEvents()
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "QingTing Setup"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(620, 420)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(620, 76)
$header.BackColor = [System.Drawing.Color]::FromArgb(232, 246, 238)
$form.Controls.Add($header)

$title = New-Label "QingTing Setup" 24 16 420 30 16 $true
$subtitle = New-Label "Music downloader and player for Windows" 24 45 420 20 9 $false
$header.Controls.Add($title)
$header.Controls.Add($subtitle)

$content = New-Object System.Windows.Forms.Panel
$content.Location = New-Object System.Drawing.Point(24, 96)
$content.Size = New-Object System.Drawing.Size(572, 238)
$form.Controls.Add($content)

$backButton = New-Object System.Windows.Forms.Button
$backButton.Text = "< Back"
$backButton.Location = New-Object System.Drawing.Point(320, 360)
$backButton.Size = New-Object System.Drawing.Size(82, 32)
$form.Controls.Add($backButton)

$nextButton = New-Object System.Windows.Forms.Button
$nextButton.Text = "Next >"
$nextButton.Location = New-Object System.Drawing.Point(412, 360)
$nextButton.Size = New-Object System.Drawing.Size(82, 32)
$form.Controls.Add($nextButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Location = New-Object System.Drawing.Point(504, 360)
$cancelButton.Size = New-Object System.Drawing.Size(82, 32)
$form.Controls.Add($cancelButton)

$form.AcceptButton = $nextButton
$form.CancelButton = $cancelButton

function Show-Page {
  $content.Controls.Clear()
  $backButton.Enabled = $state.Page -gt 0 -and $state.Page -lt 4
  $cancelButton.Enabled = $state.Page -lt 4
  $nextButton.Enabled = $true
  $nextButton.Text = "Next >"

  if ($state.Page -eq 0) {
    $content.Controls.Add((New-Label "Welcome to the QingTing Setup Wizard" 0 0 540 34 14 $true))
    $content.Controls.Add((New-Label "This wizard will install QingTing on your computer and create shortcuts for easy access." 0 48 540 44 10 $false))
    $content.Controls.Add((New-Label "Click Next to continue." 0 112 540 24 10 $false))
  }
  elseif ($state.Page -eq 1) {
    $content.Controls.Add((New-Label "Choose Install Location" 0 0 540 30 14 $true))
    $content.Controls.Add((New-Label "QingTing will be installed to the following folder." 0 42 540 24 10 $false))
    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Location = New-Object System.Drawing.Point(0, 82)
    $pathBox.Size = New-Object System.Drawing.Size(442, 28)
    $pathBox.Text = $state.InstallDir
    $content.Controls.Add($pathBox)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = "Browse..."
    $browseButton.Location = New-Object System.Drawing.Point(456, 80)
    $browseButton.Size = New-Object System.Drawing.Size(96, 30)
    $content.Controls.Add($browseButton)
    $browseButton.Add_Click({
      $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
      $dialog.Description = "Choose where to install QingTing."
      $dialog.SelectedPath = $pathBox.Text
      if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = Join-Path $dialog.SelectedPath "QingTing"
      }
    })
    $pathBox.Add_TextChanged({ $state.InstallDir = $pathBox.Text })
  }
  elseif ($state.Page -eq 2) {
    $content.Controls.Add((New-Label "Select Additional Tasks" 0 0 540 30 14 $true))
    $desktop = New-Object System.Windows.Forms.CheckBox
    $desktop.Text = "Create a desktop shortcut"
    $desktop.Location = New-Object System.Drawing.Point(0, 52)
    $desktop.Size = New-Object System.Drawing.Size(320, 28)
    $desktop.Checked = $state.CreateDesktopShortcut
    $content.Controls.Add($desktop)

    $startMenu = New-Object System.Windows.Forms.CheckBox
    $startMenu.Text = "Create Start Menu shortcuts"
    $startMenu.Location = New-Object System.Drawing.Point(0, 88)
    $startMenu.Size = New-Object System.Drawing.Size(320, 28)
    $startMenu.Checked = $state.CreateStartMenuShortcut
    $content.Controls.Add($startMenu)

    $desktop.Add_CheckedChanged({ $state.CreateDesktopShortcut = $desktop.Checked })
    $startMenu.Add_CheckedChanged({ $state.CreateStartMenuShortcut = $startMenu.Checked })
  }
  elseif ($state.Page -eq 3) {
    $content.Controls.Add((New-Label "Ready to Install" 0 0 540 30 14 $true))
    $summary = "Install location:`r`n$($state.InstallDir)`r`n`r`nDesktop shortcut: $($state.CreateDesktopShortcut)`r`nStart Menu shortcuts: $($state.CreateStartMenuShortcut)"
    $content.Controls.Add((New-Label $summary 0 48 540 120 10 $false))
    $nextButton.Text = "Install"
  }
  elseif ($state.Page -eq 4) {
    $backButton.Enabled = $false
    $cancelButton.Enabled = $false
    $nextButton.Enabled = $false
    $content.Controls.Add((New-Label "Installing QingTing" 0 0 540 30 14 $true))
    $status = New-Label "Starting..." 0 56 540 26 10 $false
    $content.Controls.Add($status)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(0, 96)
    $bar.Size = New-Object System.Drawing.Size(552, 24)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $bar.Value = 0
    $content.Controls.Add($bar)
    $form.Refresh()
    try {
      Install-App -StatusLabel $status -ProgressBar $bar
      $state.Page = 5
      Show-Page
    }
    catch {
      [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        "QingTing Setup",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      ) | Out-Null
      $state.Page = 3
      Show-Page
    }
  }
  elseif ($state.Page -eq 5) {
    $backButton.Enabled = $false
    $cancelButton.Enabled = $false
    $nextButton.Enabled = $true
    $nextButton.Text = "Finish"
    $content.Controls.Add((New-Label "Completing the QingTing Setup Wizard" 0 0 540 30 14 $true))
    $content.Controls.Add((New-Label "QingTing has been installed successfully." 0 50 540 28 10 $false))
    $runBox = New-Object System.Windows.Forms.CheckBox
    $runBox.Text = "Launch QingTing now"
    $runBox.Location = New-Object System.Drawing.Point(0, 92)
    $runBox.Size = New-Object System.Drawing.Size(320, 28)
    $runBox.Checked = $state.RunAfterInstall
    $content.Controls.Add($runBox)
    $runBox.Add_CheckedChanged({ $state.RunAfterInstall = $runBox.Checked })
  }
}

$nextButton.Add_Click({
  if ($state.Page -eq 5) {
    if ($state.RunAfterInstall -and $state.InstalledExe -and (Test-Path -LiteralPath $state.InstalledExe)) {
      Start-Process -FilePath $state.InstalledExe -WorkingDirectory (Split-Path -Parent $state.InstalledExe)
    }
    $form.Close()
    return
  }

  if ($state.Page -eq 1 -and [string]::IsNullOrWhiteSpace($state.InstallDir)) {
    [System.Windows.Forms.MessageBox]::Show(
      "Please choose an install location.",
      "QingTing Setup",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return
  }

  $state.Page++
  Show-Page
})

$backButton.Add_Click({
  if ($state.Page -gt 0) {
    $state.Page--
    Show-Page
  }
})

$cancelButton.Add_Click({
  if ([System.Windows.Forms.MessageBox]::Show(
      "Exit QingTing Setup?",
      "QingTing Setup",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    ) -eq [System.Windows.Forms.DialogResult]::Yes) {
    $form.Close()
  }
})

Show-Page
[System.Windows.Forms.Application]::Run($form)
