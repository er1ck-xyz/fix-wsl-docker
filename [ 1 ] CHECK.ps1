# Diagnóstico do erro WSL/Docker 0x80070569

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$vmSid   = 'S-1-5-83-0'   # NT VIRTUAL MACHINE\Virtual Machines
$work    = Join-Path $env:TEMP 'fix-wsl-docker'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Start-Transcript -Path (Join-Path $work 'verificar.log') -Force | Out-Null

function Show-Result($ok, $text) {
    if ($ok) { Write-Host "  [OK]    $text" -ForegroundColor Green }
    else     { Write-Host "  [FALHA] $text" -ForegroundColor Red }
}

$problemas = 0

Write-Host "`n[1] GPOs do domínio que mexem em 'Fazer logon como um serviço'" -ForegroundColor Cyan
$gpoNames = @{}
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List' -ErrorAction SilentlyContinue |
    ForEach-Object { $p = Get-ItemProperty $_.PSPath; $gpoNames[$p.GPOID] = $p.DisplayName }
$encontrou = $false
Get-ChildItem 'C:\Windows\System32\GroupPolicy\DataStore' -Recurse -Filter GptTmpl.inf -ErrorAction SilentlyContinue | ForEach-Object {
    $linha = Select-String -Path $_.FullName -Pattern '^SeServiceLogonRight\s*=' | Select-Object -First 1
    if ($linha) {
        $encontrou = $true
        $guid = [regex]::Match($_.FullName, '\{[0-9A-Fa-f-]{36}\}').Value
        $nome = if ($gpoNames[$guid]) { $gpoNames[$guid] } else { $guid }
        $valor = ($linha.Line -split '=', 2)[1].Trim()
        $temVm = $valor -match [regex]::Escape($vmSid)
        if (-not $temVm) { Write-Host "  [AVISO] GPO '$nome' define o direito como: '$valor' (sem o grupo Virtual Machines)" -ForegroundColor Yellow }
        else             { Show-Result $true "GPO '$nome' já inclui o grupo Virtual Machines" }
    }
}
if (-not $encontrou) { Write-Host "  Nenhuma GPO do domínio define esse direito." }

Write-Host "`n[2] Política efetiva nesta máquina" -ForegroundColor Cyan
$cfg = Join-Path $work 'verificar.inf'
secedit /export /cfg $cfg /areas USER_RIGHTS | Out-Null
$linha = (Get-Content $cfg -Encoding Unicode) | Where-Object { $_ -match '^SeServiceLogonRight\s*=' }
$temDireito = $linha -and ($linha -match [regex]::Escape("*$vmSid"))
Show-Result $temDireito ("Grupo Virtual Machines (*$vmSid) em SeServiceLogonRight" + $(if ($linha) { "  ->  $linha" } else { "  ->  (direito vazio)" }))
if (-not $temDireito) { $problemas++ }

Write-Host "`n[3] Serviços do Hyper-V / WSL" -ForegroundColor Cyan
foreach ($svc in 'vmcompute', 'vmms', 'hns', 'WSLService') {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $s) { Write-Host "  [--]    $svc não encontrado"; continue }
    $ok = $s.Status -eq 'Running' -or $s.StartType -eq 'Manual'
    Show-Result $ok "$svc : $($s.Status) ($($s.StartType))"
    if (-not $ok) { $problemas++ }
}

Write-Host "`n[4] Teste de inicialização da VM do WSL (docker-desktop)" -ForegroundColor Cyan
$env:WSL_UTF8 = 1
$saida = (wsl -d docker-desktop -u root -e echo WSL-OK 2>&1 | Out-String).Trim()
$wslOk = $saida -match 'WSL-OK'
Show-Result $wslOk $(if ($wslOk) { 'WSL inicia normalmente' } else { "WSL não iniciou: $saida" })
if (-not $wslOk) { $problemas++ }

Write-Host "`n[5] Docker Engine" -ForegroundColor Cyan
$versao = docker version --format '{{.Server.Version}}' 2>$null
$dockerOk = $LASTEXITCODE -eq 0 -and $versao
Show-Result $dockerOk $(if ($dockerOk) { "Docker Engine respondendo (versão $versao)" } else { 'Docker Engine não está respondendo (o Docker Desktop está aberto?)' })

Write-Host "`n================ RESULTADO ================" -ForegroundColor Cyan
if (-not $temDireito -or -not $wslOk) {
    Write-Host "Problema detectado: o grupo Virtual Machines está sem o direito 'Fazer logon como um serviço'." -ForegroundColor Red
    Write-Host "Execute o 2-corrigir.ps1 para aplicar a correção." -ForegroundColor Yellow
} elseif (-not $dockerOk) {
    Write-Host "O WSL está OK. Basta abrir (ou reiniciar) o Docker Desktop." -ForegroundColor Yellow
} else {
    Write-Host "Tudo funcionando." -ForegroundColor Green
}
Write-Host "Log salvo em: $work\verificar.log"

Stop-Transcript | Out-Null
Read-Host "`nPressione Enter para fechar"
