<#
 COMPARTDISK 1.3.0 - Users.ps1
 Desenvolvido por Edsilas
 Acoes: List | Groups | Audit | ClearPassword | SetPassword | EnableAdmin | DisableAdmin
 Toda alteracao de conta e registrada no log como evento de seguranca.
#>
[CmdletBinding()]
param(
    [ValidateSet('List', 'Groups', 'Audit', 'ClearPassword', 'SetPassword', 'EnableAdmin', 'DisableAdmin')]
    [string]$Action = 'List',
    [string]$User = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Get-BuiltinAdminName {
    # A conta interna termina sempre em -500, independente do idioma
    try {
        if (Test-CompartDiskCommand 'Get-LocalUser') {
            $u = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
            if ($u) { return $u.Name }
        }
        $w = Get-CompartDiskCim -Class Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object { $_.SID -match '-500$' } | Select-Object -First 1
        if ($w) { return $w.Name }
    } catch { }
    return $null
}

function Show-Users {
    $u = Get-CompartDiskLocalUsers
    if ($u.Count -eq 0) {
        Write-Log WARN 'Nenhuma conta local enumerada.'
        $script:result = 'WARN'
        return
    }
    Write-Color ''
    $u | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Contas locais' -Status OK -Rows $u -Summary "$($u.Count) conta(s)"

    foreach ($c in $u) {
        if ($c.Habilitado -eq $true -and $c.SenhaRequerida -eq $false) {
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Conta '$($c.Usuario)' habilitada sem exigencia de senha." -Recommendation 'Definir uma senha ou desabilitar a conta.'
            $script:result = 'WARN'
        }
    }
    $admin = Get-BuiltinAdminName
    if ($admin) {
        $conta = $u | Where-Object { $_.Usuario -eq $admin }
        if ($conta -and $conta.Habilitado -eq $true) {
            Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Conta interna de Administrador ('$admin') esta habilitada." -Recommendation 'Manter desabilitada em ambiente corporativo; usar contas nominais.'
        }
    }
    Write-Log OK "$($u.Count) conta(s) local(is) listada(s)."
}

function Show-Groups {
    $rows = New-Object System.Collections.ArrayList
    if (Test-CompartDiskCommand 'Get-LocalGroup') {
        foreach ($g in (Get-LocalGroup -ErrorAction SilentlyContinue)) {
            $membros = @()
            try { $membros = (Get-LocalGroupMember -Group $g.Name -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
            [void]$rows.Add([pscustomobject]@{
                Grupo    = $g.Name
                Descricao= $g.Description
                Membros  = $(if ($membros.Count -gt 0) { ($membros -join '; ') } else { '(vazio)' })
                Total    = $membros.Count
            })
        }
    } else {
        foreach ($g in (Get-CompartDiskCim -Class Win32_Group -Filter 'LocalAccount=True')) {
            [void]$rows.Add([pscustomobject]@{ Grupo = $g.Name; Descricao = $g.Description; Membros = 'n/d'; Total = 'n/d' })
        }
    }
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Output
    Add-CompartDiskSection -Title 'Grupos locais' -Status INFO -Rows @($rows)

    $adm = $rows | Where-Object { $_.Grupo -match 'Administrador|Administrators' } | Select-Object -First 1
    if ($adm -and $adm.Total -gt 3) {
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Grupo de administradores possui $($adm.Total) membros." -Recommendation 'Revisar o principio do menor privilegio.'
    }
    Write-Log OK 'Grupos locais listados.'
}

function Show-Audit {
    Show-Users
    Show-Groups

    Write-Log INFO 'Coletando politicas de senha e eventos de logon...'
    $netExe = Join-Path $env:SystemRoot 'System32\net.exe'
    $r = Invoke-SafeCommand { Invoke-NativeCommand -FilePath $netExe -Arguments @('accounts') -TimeoutSeconds 30 } -Activity 'net accounts'
    if ($r.Success -and $r.Value.StdOut) {
        Write-Output $r.Value.StdOut
        $pares = [ordered]@{}
        foreach ($linha in ($r.Value.StdOut -split '\r?\n')) {
            if ($linha -match '^(.+?):\s+(.+)$') { $pares[$matches[1].Trim()] = $matches[2].Trim() }
        }
        if ($pares.Count -gt 0) { Add-CompartDiskSection -Title 'Politica de contas' -Status INFO -Pairs $pares }
    }

    # Falhas de logon recentes (evento 4625)
    $falhas = Invoke-SafeCommand {
        Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction Stop
    } -Activity 'Eventos 4625' -Silent
    if ($falhas.Success -and $falhas.Value) {
        $n = @($falhas.Value).Count
        Write-Log WARN "$n falha(s) de logon nos ultimos 7 dias."
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "$n falha(s) de autenticacao nos ultimos 7 dias." -Recommendation 'Investigar origem em caso de volume anormal.'
        $rows = @($falhas.Value | Select-Object -First 15 | ForEach-Object {
            [pscustomobject]@{ Data = $_.TimeCreated; Evento = $_.Id; Mensagem = (($_.Message -split '\r?\n')[0]) }
        })
        Add-CompartDiskSection -Title 'Falhas de logon (7 dias)' -Status WARN -Rows $rows
    } else {
        Add-CompartDiskFinding -Severity OK -Area 'Contas' -Message 'Nenhuma falha de logon relevante nos ultimos 7 dias.'
    }
}

function Set-UserPassword {
    param([string]$Nome, [switch]$Clear)

    if ([string]::IsNullOrWhiteSpace($Nome)) {
        Write-Log ERR 'Nenhum usuario informado.'
        $script:result = 'ERROR'
        return
    }

    $conta = $null
    if (Test-CompartDiskCommand 'Get-LocalUser') {
        try { $conta = Get-LocalUser -Name $Nome -ErrorAction Stop } catch { }
    }
    if (-not $conta) {
        $nomeWql = $Nome.Replace("'", "''")
        $conta = Get-CompartDiskCim -Class Win32_UserAccount -Filter "LocalAccount=True AND Name='$nomeWql'"
    }
    if (-not $conta) {
        Write-Log ERR "Conta local '$Nome' nao encontrada. Verifique a grafia exata (use a acao List)."
        $script:result = 'ERROR'
        return
    }

    if ($Clear) {
        Write-Log WARN "OPERACAO SENSIVEL: removendo a senha da conta local '$Nome'."
        Write-Color ''
        Write-Color '  Uma conta sem senha permite logon local sem autenticacao.' -Color Yellow
        Write-Color '  Esta acao sera registrada no log de manutencao.' -Color Yellow
        Write-Color ''
        $c = Read-Host "  Digite exatamente REMOVER para confirmar (qualquer outra entrada cancela)"
        if ($c -ne 'REMOVER') {
            Write-Log INFO 'Operacao cancelada pelo operador.'
            return
        }

        if (Test-CompartDiskCommand 'Set-LocalUser') {
            Invoke-SafeCommand {
                Set-LocalUser -Name $Nome -Password ([securestring]::new()) -ErrorAction Stop
            } -Activity "Remover senha de $Nome" -Critical | Out-Null
        } else {
            $r = Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\net.exe') -Arguments @('user', "`"$Nome`"", '""') -TimeoutSeconds 60
            if ($r.ExitCode -ne 0) { throw "net user retornou $($r.ExitCode): $($r.StdErr)" }
        }
        Write-Log OK "Senha da conta '$Nome' removida por $($Global:CompartDisk.User) em $($Global:CompartDisk.Computer)."
        Add-CompartDiskFinding -Severity WARN -Area 'Contas' -Message "Senha removida da conta local '$Nome'." -Recommendation 'Definir uma nova senha assim que o acesso for restabelecido.'
        $script:result = 'WARN'
        return
    }

    # Conta vinculada a e-mail: trocar a senha local aqui nao muda a senha da
    # Microsoft e costuma impedir o logon. Melhor recusar do que "funcionar".
    $tipo = $null
    try { $tipo = $conta.PrincipalSource } catch { }
    if ("$tipo" -eq 'MicrosoftAccount') {
        Write-Color ''
        Write-Color "  A conta '$Nome' e uma CONTA MICROSOFT (entra com e-mail)." -Color Yellow
        Write-Color '  Trocar a senha por aqui nao altera a senha da Microsoft e pode' -Color Yellow
        Write-Color '  impedir a entrada no Windows.' -Color Yellow
        Write-Color ''
        Write-Color '  Troque em: account.microsoft.com  (ou pelo celular)' -Color Gray
        Write-Color ''
        Write-Log WARN "Operacao recusada: '$Nome' e conta Microsoft."
        $script:result = 'WARN'
        return
    }

    # Se o computador entra sozinho, a senha atual pode ser desconhecida do
    # proprio dono. Definir uma nova fara o Windows passar a pedi-la.
    $auto = Get-CompartDiskRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon'
    if ("$auto" -eq '1') {
        Write-Color ''
        Write-Color '  Este computador entra no Windows automaticamente, sem pedir senha.' -Color Yellow
        Write-Color '  Ao definir uma senha, ele passara a pedi-la em todo login.' -Color Yellow
        Write-Color ''
    }

    Write-Color ''
    Write-Color "  Conta que sera alterada: $Nome" -Color White
    Write-Color '  A senha nao aparece na tela enquanto voce digita. Isso e normal.' -Color DarkGray
    Write-Color '  Anote a senha antes de digitar. Pressione Enter vazio para cancelar.' -Color DarkGray
    Write-Color ''
    $senha = Read-Host "  Nova senha para '$Nome'" -AsSecureString
    $conf  = Read-Host "  Confirme a senha" -AsSecureString

    # Comparar exige o texto claro, mas ele nao pode ficar residente: o BSTR e
    # memoria NAO gerenciada, que o coletor de lixo jamais recupera, e a String
    # gerenciada sobreviveria ate uma coleta futura. Os ponteiros sao zerados e
    # liberados no finally, inclusive se algo lancar no meio.
    $ptrSenha = [IntPtr]::Zero
    $ptrConf  = [IntPtr]::Zero
    $coincidem = $false
    $vazia     = $true
    try {
        $ptrSenha = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($senha)
        $ptrConf  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($conf)
        $a = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptrSenha)
        $b = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptrConf)
        $coincidem = ($a -eq $b)
        $vazia     = [string]::IsNullOrEmpty($a)
        $a = $null; $b = $null
    } finally {
        if ($ptrSenha -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptrSenha) }
        if ($ptrConf  -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptrConf) }
    }

    if (-not $coincidem) {
        Write-Log ERR 'As senhas nao coincidem. Operacao cancelada.'
        $script:result = 'ERROR'
        return
    }
    if ($vazia) {
        Write-Log ERR 'Senha vazia. Use a acao ClearPassword se a intencao for remover a senha.'
        $script:result = 'ERROR'
        return
    }

    Write-Color ''
    Write-Color "  Confirmar a troca de senha da conta '$Nome'?" -Color Yellow
    $ok = Read-Host '  Digite S para confirmar (qualquer outra tecla cancela)'
    if ($ok -notmatch '^[Ss]$') {
        Write-Log INFO 'Operacao cancelada pelo operador. Nenhuma senha foi alterada.'
        return
    }

    if (Test-CompartDiskCommand 'Set-LocalUser') {
        Invoke-SafeCommand { Set-LocalUser -Name $Nome -Password $senha -ErrorAction Stop } -Activity "Definir senha de $Nome" -Critical | Out-Null
    } else {
        # Mesma degradacao que o ramo ClearPassword ja adotava: sem o modulo
        # LocalAccounts, a interface ADSI WinNT e o equivalente nativo. net.exe
        # nao serve aqui - com a saida redirecionada, seu prompt de senha ficaria
        # invisivel e a ferramenta pareceria travada.
        $ptrAplicar = [IntPtr]::Zero
        try {
            $ptrAplicar = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($senha)
            $claro = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptrAplicar)
            $contaAdsi = [ADSI]("WinNT://./{0},user" -f $Nome)
            $contaAdsi.SetPassword($claro)
            $contaAdsi.SetInfo()
            $claro = $null
        } finally {
            if ($ptrAplicar -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptrAplicar) }
        }
    }
    Write-Log OK "Senha da conta '$Nome' redefinida por $($Global:CompartDisk.User)."
    Write-Color ''
    Write-Color '  Guarde a senha em local seguro. Ela sera pedida no proximo login.' -Color Yellow
    Write-Color ''
    Add-CompartDiskFinding -Severity OK -Area 'Contas' -Message "Senha redefinida para a conta '$Nome'."
}

function Set-BuiltinAdmin {
    param([bool]$Habilitar)

    $nome = Get-BuiltinAdminName
    if (-not $nome) {
        Write-Log ERR 'Conta interna de Administrador (SID -500) nao localizada.'
        $script:result = 'ERROR'
        return
    }

    $acao     = if ($Habilitar) { 'habilitar' }  else { 'desabilitar' }
    $acaoFeita = if ($Habilitar) { 'habilitada' } else { 'desabilitada' }
    Write-Log INFO "Preparando para $acao a conta interna '$nome'."

    if ($Habilitar) {
        Write-Color ''
        Write-Color '  A conta interna de Administrador nao possui senha por padrao.' -Color Yellow
        Write-Color '  Recomendacao corporativa: manter desabilitada e usar contas nominais.' -Color Yellow
        Write-Color ''
    }

    if (Test-CompartDiskCommand 'Enable-LocalUser') {
        Invoke-SafeCommand {
            if ($Habilitar) { Enable-LocalUser -Name $nome -ErrorAction Stop }
            else            { Disable-LocalUser -Name $nome -ErrorAction Stop }
        } -Activity "$acao conta $nome" -Critical | Out-Null
    } else {
        $flag = if ($Habilitar) { '/active:yes' } else { '/active:no' }
        $r = Invoke-NativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\net.exe') -Arguments @('user', "`"$nome`"", $flag) -TimeoutSeconds 60
        if ($r.ExitCode -ne 0) { throw "net user retornou $($r.ExitCode)" }
    }

    Write-Log OK "Conta '$nome' $acaoFeita por $($Global:CompartDisk.User)."
    $sev = if ($Habilitar) { 'WARN' } else { 'OK' }
    Add-CompartDiskFinding -Severity $sev -Area 'Contas' -Message "Conta interna de Administrador '$nome' foi $acaoFeita." `
        -Recommendation $(if ($Habilitar) { 'Definir senha forte imediatamente e desabilitar apos o uso.' } else { '' })
}

# ------------------------------------------------------------------------------
try {
    $precisaAdmin = @('ClearPassword', 'SetPassword', 'EnableAdmin', 'DisableAdmin') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Users' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }

    switch ($Action) {
        'List'          { Show-Users }
        'Groups'        { Show-Groups }
        'Audit'         { Show-Audit }
        'ClearPassword' { Set-UserPassword -Nome $User -Clear }
        'SetPassword'   { Set-UserPassword -Nome $User }
        'EnableAdmin'   { Set-BuiltinAdmin -Habilitar $true }
        'DisableAdmin'  { Set-BuiltinAdmin -Habilitar $false }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Users (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Contas' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
