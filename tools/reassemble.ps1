$ErrorActionPreference = 'Stop'
Set-Location C:\Users\xyzsu\hapx
$target = 'C:\Users\xyzsu\hapx\entry-signed.hap'
if (Test-Path $target) { Remove-Item $target -Force }
$out = [System.IO.File]::Create($target)
Get-ChildItem part* | Sort-Object Name | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $out.Write($bytes, 0, $bytes.Length)
}
$out.Close()
$item = Get-Item $target
$hash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLower()
Write-Output ("len=" + $item.Length)
Write-Output ("sha16=" + $hash.Substring(0, 16))