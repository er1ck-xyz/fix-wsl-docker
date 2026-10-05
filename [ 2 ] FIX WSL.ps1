# Correção do erro WSL/Docker 0x80070569 sem reiniciar o PC.
# Inclui o grupo NT VIRTUAL MACHINE\Virtual Machines no direito "Fazer logon como um serviço",
# reinicia o WSL / vmcompute e reabre o Docker Desktop. Pede elevação (UAC).

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$vmSid = '*S-1-5-83-0'   # NT VIRTUAL MACHINE\Virtual Machines
$work  = Join-Path $env:TEMP 'fix-wsl-docker'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Start-Transcript -Path (Join-Path $work 'corrigir.log') -Force | Out-Null

try {
    $cfg = Join-Path $work 'corrigir.inf'
    $db  = Join-Path $work 'corrigir.sdb'

    Write-Host "`n[1/4] Ajustando a política 'Fazer logon como um serviço'..." -ForegroundColor Cyan
    secedit /export /cfg $cfg /areas USER_RIGHTS | Out-Null
    $content = @(Get-Content $cfg -Encoding Unicode)
    $linha = $content | Where-Object { $_ -match '^SeServiceLogonRight\s*=' }
    Write-Host "  Antes : $(if ($linha) { $linha } else { '(direito vazio)' })"

    if ($linha -and $linha -match [regex]::Escape($vmSid)) {
        Write-Host "  O grupo Virtual Machines já tem o direito. Nada a alterar." -ForegroundColor Green
    } else {
        if ($linha) {
            $atual = ($linha -split '=', 2)[1].Trim()
            $novo  = if ($atual) { "$atual,$vmSid" } else { $vmSid }
            $content = $content -replace '^SeServiceLogonRight\s*=.*$', "SeServiceLogonRight = $novo"
        } else {
            $idx  = [array]::IndexOf($content, '[Privilege Rights]')
            $list = [System.Collections.Generic.List[string]]$content
            $list.Insert($idx + 1, "SeServiceLogonRight = $vmSid")
            $content = $list.ToArray()
        }
        $content | Set-Content $cfg -Encoding Unicode
        secedit /configure /db $db /cfg $cfg /areas USER_RIGHTS /quiet
        secedit /export /cfg $cfg /areas USER_RIGHTS | Out-Null
        $depois = (Get-Content $cfg -Encoding Unicode) | Where-Object { $_ -match '^SeServiceLogonRight\s*=' }
        Write-Host "  Depois: $depois"
        if ($depois -notmatch [regex]::Escape($vmSid)) { throw 'A política não foi aplicada.' }
    }

    Write-Host "`n[2/4] Reiniciando WSL e o serviço vmcompute..." -ForegroundColor Cyan
    Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue | Stop-Process -Force
    wsl --shutdown
    Restart-Service vmcompute -Force

    Write-Host "`n[3/4] Testando a VM do WSL..." -ForegroundColor Cyan
    $env:WSL_UTF8 = 1
    $saida = (wsl -d docker-desktop -u root -e echo WSL-OK 2>&1 | Out-String).Trim()
    if ($saida -notmatch 'WSL-OK') { throw "O WSL ainda não inicia: $saida" }
    Write-Host "  WSL OK" -ForegroundColor Green
    wsl --shutdown

    Write-Host "`n[4/4] Abrindo o Docker Desktop e aguardando o engine (até 3 min)..." -ForegroundColor Cyan
    # Abre via explorer para o Docker Desktop rodar como usuário normal (não como administrador)
    Start-Process explorer.exe "`"C:\Program Files\Docker\Docker\Docker Desktop.exe`""
    $pronto = $false
    for ($i = 0; $i -lt 36; $i++) {
        Start-Sleep 5
        docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $pronto = $true; break }
    }
    if ($pronto) {
        Write-Host "  Docker Engine pronto (versão $(docker version --format '{{.Server.Version}}' 2>$null))" -ForegroundColor Green
        Write-Host "`nCORRIGIDO." -ForegroundColor Green
    } else {
        Write-Host "  O WSL está OK, mas o Docker ainda não respondeu. Aguarde mais um pouco ou reabra o Docker Desktop." -ForegroundColor Yellow
    }
    Write-Host "Lembre-se: a GPO do domínio pode desfazer isso em até ~16h. O definitivo é o chamado na TI (veja LEIA-ME.txt)."
} catch {
    Write-Host "`nERRO: $_" -ForegroundColor Red
} finally {
    Write-Host "Log salvo em: $work\corrigir.log"
    Stop-Transcript | Out-Null
}
Read-Host "`nPressione Enter para fechar"
