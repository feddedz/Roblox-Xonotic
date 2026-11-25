# Pop-up to save the Roblox Open Cloud API key on a Windows PC, for tools/upload/run_unattended.ps1.
#   powershell -ExecutionPolicy Bypass -File tools\upload\set_key.ps1
# The key is typed into a masked box and saved as the Windows user variable ROBLOX_API_KEY. It is never printed,
# logged, or written into the repo. Remove it again with:  set_key.ps1 -Remove
param([switch]$Remove)
if ($Remove) {
    [Environment]::SetEnvironmentVariable("ROBLOX_API_KEY", $null, "User")
    Write-Output "ROBLOX_API_KEY removed."
    exit 0
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Roblox API key - Xonotic upload"
$form.ClientSize = New-Object System.Drawing.Size(520, 190)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(16, 14)
$label.Size = New-Object System.Drawing.Size(488, 74)
$label.Text = "Paste your Roblox Open Cloud API key (Ctrl+V) and press Save.`r`n`r`n" +
    "It is saved only in your Windows user settings (ROBLOX_API_KEY). It is not shown in the chat, " +
    "not sent to Claude, and not written into the repo."
$form.Controls.Add($label)

$box = New-Object System.Windows.Forms.TextBox
$box.Location = New-Object System.Drawing.Point(16, 96)
$box.Size = New-Object System.Drawing.Size(488, 24)
$box.UseSystemPasswordChar = $true
$box.MaxLength = 4096
$form.Controls.Add($box)

$ok = New-Object System.Windows.Forms.Button
$ok.Text = "Save"
$ok.Location = New-Object System.Drawing.Point(316, 140)
$ok.Size = New-Object System.Drawing.Size(90, 30)
$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($ok)
$form.AcceptButton = $ok

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = "Cancel"
$cancel.Location = New-Object System.Drawing.Point(414, 140)
$cancel.Size = New-Object System.Drawing.Size(90, 30)
$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$form.CancelButton = $cancel

$form.Add_Shown({ $form.Activate(); $box.Focus() })
$result = $form.ShowDialog()
$key = $box.Text.Trim()
$form.Dispose()

if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $key) {
    Write-Output "KEY NOT SAVED (cancelled or empty)."
    exit 1
}
[Environment]::SetEnvironmentVariable("ROBLOX_API_KEY", $key, "User")
$key = $null
Write-Output "KEY SAVED as the Windows user variable ROBLOX_API_KEY."
