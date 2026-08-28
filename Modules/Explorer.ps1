<#
 COMPARTDISK 1.5.0 - Explorer.ps1
 Desenvolvido por Edsilas
 Acoes: Restart | ClearCache | Spooler | ResetView
#>
[CmdletBinding()]
param(
    [ValidateSet('Restart', 'ClearCache', 'Spooler', 'ResetView')]
    [string]$Action = 'Restart',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Restart-ShellExplorer {
    Write-Log INFO 'Reiniciando o shell do Windows...'
    $antes = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count

    Invoke-SafeCommand {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
    } -Activity 'Encerrar explorer.exe' | Out-Null

    Start-Sleep -Seconds 2

    # O Windows reinicia o shell automaticamente quando ele e a shell padrao.
    $depois = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count
    if ($depois -eq 0) {
        Invoke-WithRetry -Activity 'Iniciar explorer.exe' -Retries 3 -DelaySeconds 2 -ScriptBlock {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction Stop
            Start-Sleep -Seconds 2
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { throw 'Explorer nao iniciou.' }
            $true
        } | Out-Null
    }

    $final = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count
    if ($final -gt 0) {
        Write-Log OK "Interface do Windows reiniciada ($antes -> $final processo(s))."
        Add-CompartDiskFinding -Severity OK -Area 'Explorer' -Message 'Shell do Windows reiniciado com sucesso.'
    } else {
        $script:result = 'ERROR'
        Write-Log ERR 'O Explorer nao voltou a executar. Use Ctrl+Shift+Esc > Arquivo > Executar nova tarefa > explorer.exe'
        Add-CompartDiskFinding -Severity CRIT -Area 'Explorer' -Message 'Shell do Windows nao reiniciou automaticamente.' -Recommendation 'Iniciar explorer.exe manualmente pelo Gerenciador de Tarefas.'
    }
}

function Clear-ShellCache {
    <# Reconstroi o cache de icones e miniaturas.

       A classificacao final representa o SIGNIFICADO da condicao, nao a
       contagem de arquivos removidos:

         diretorio ausente          -> OK          (nada a reconstruir; shell reiniciado)
         diretorio inacessivel      -> WARN        (nao e "nao aplicavel": e negativa de acesso)
         nao havia arquivo elegivel -> OK          (objetivo ja atendido)
         todos removidos            -> OK
         parte removida             -> WARN        (reconstrucao parcial)
         havia elegiveis, zero saiu -> WARN        (reconstrucao impedida)
         shell nao voltou           -> ERROR

       Antes, as tres ultimas condicoes terminavam em OK: a funcao publicava
       "Cache de icones e miniaturas reconstruido (0 arquivos)" para uma
       execucao em que nada foi removido, e o catch do IconCache.db legado era
       vazio - uma falha ali desaparecia por completo.

       O REINICIO DO SHELL NAO DEPENDE DO CACHE e acontece em todos os caminhos
       que nao sejam falha do proprio shell. A versao anterior devolvia antes de
       encerrar o Explorer quando o diretorio nao era encontrado - e, como a
       etapa 5 do Reparo Geral Automatico passou a usar esta acao, aquele
       retorno deixava a etapa inteira sem executar nada. A rotina Batch
       equivalente (:FB_EXPLORER_CACHE) sempre reiniciou o shell nesse caso: os
       dois caminhos voltam a ter o mesmo desfecho. #>
    Write-Log INFO 'Limpando caches de icones e miniaturas...'
    $base = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'

    # Test-Path devolve $false tanto para "nao existe" quanto para "acesso
    # negado", e tratar os dois como a mesma coisa mapearia uma negativa de
    # acesso para uma condicao benigna.
    #
    # MEDIDO: com -ErrorAction Stop o Test-Path lanca UnauthorizedAccessException
    # quando a travessia CHEGA ao alvo negado (por exemplo
    # ...\systemprofile\AppData\Local), mas devolve $false silenciosamente quando
    # a travessia ja falha antes, num diretorio intermediario. A deteccao e
    # portanto PARCIAL: pega o que da para pegar e nunca classifica um diretorio
    # realmente ausente como inacessivel. O caso que escapa cai em 'ausente' e
    # continua visivel na secao, com o shell reiniciado do mesmo jeito - o que
    # muda e apenas a severidade, nunca a acao executada.
    $baseEstado  = 'ok'
    $baseDetalhe = ''
    try {
        if (-not (Test-Path -LiteralPath $base -ErrorAction Stop)) {
            $baseEstado  = 'ausente'
            $baseDetalhe = 'o diretorio de cache nao existe neste perfil'
        }
    } catch {
        $baseEstado  = 'inacessivel'
        $baseDetalhe = ('o diretorio de cache nao pode ser lido: {0}' -f $_.Exception.Message)
    }

    if ($baseEstado -ne 'ok') {
        Write-Log WARN ('Cache de icones nao sera reconstruido: {0}.' -f $baseDetalhe)
        Restart-ShellExplorer
        # Restart-ShellExplorer ja classificou e publicou o achado se o shell
        # nao voltou: nesse caso o resultado do modulo e ERROR e nao ha o que
        # acrescentar sobre o cache.
        if ($script:result -eq 'ERROR') { return }

        $inacessivel = ($baseEstado -eq 'inacessivel')
        if ($inacessivel) { $script:result = 'WARN' }
        Add-CompartDiskSection -Title 'Cache do Explorer' -Status $(if ($inacessivel) { 'WARN' } else { 'INFO' }) `
            -Summary $(if ($inacessivel) { 'Cache inacessivel; shell reiniciado' } else { 'Sem cache neste perfil; shell reiniciado' }) `
            -Pairs ([ordered]@{
                'Diretorio'         = $base
                'Situacao'          = $baseDetalhe
                'Reinicio do shell' = 'executado e confirmado'
            })
        Add-CompartDiskFinding -Severity $(if ($inacessivel) { 'WARN' } else { 'INFO' }) -Area 'Explorer' `
            -Message ('Cache de icones e miniaturas nao reconstruido: {0}. O shell do Windows foi reiniciado.' -f $baseDetalhe) `
            -Recommendation $(if ($inacessivel) { 'Conferir as permissoes do perfil ou executar a acao na sessao do usuario afetado.' } else { '' })
        return
    }

    # Inventario ANTES de encerrar o shell. Sem ele nao ha como distinguir
    # "nao havia nada a remover" de "havia arquivos e nenhum saiu".
    $elegiveis = New-Object System.Collections.ArrayList
    foreach ($padrao in @('thumbcache_*.db', 'iconcache_*.db')) {
        foreach ($f in (Get-ChildItem -LiteralPath $base -Filter $padrao -Force -ErrorAction SilentlyContinue)) {
            [void]$elegiveis.Add($f)
        }
    }
    $legado = Join-Path $env:LOCALAPPDATA 'IconCache.db'
    $temLegado = Test-Path -LiteralPath $legado
    $totalElegiveis = $elegiveis.Count + $(if ($temLegado) { 1 } else { 0 })

    # O Explorer mantem os arquivos abertos: encerrar primeiro
    Invoke-SafeCommand { Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force } -Activity 'Encerrar explorer' | Out-Null
    Start-Sleep -Seconds 2

    $liberado = 0
    $removidos = 0
    $bloqueados = 0
    $nomesBloqueados = New-Object System.Collections.ArrayList
    foreach ($f in $elegiveis) {
        try {
            $sz = $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $liberado += $sz
            $removidos++
        } catch {
            $bloqueados++
            [void]$nomesBloqueados.Add($f.Name)
            Write-Log DEBUG "Bloqueado: $($f.Name) - $($_.Exception.Message)" -NoConsole
        }
    }

    if ($temLegado) {
        try {
            # -Force e obrigatorio aqui: o Windows cria %LOCALAPPDATA%\IconCache.db
            # com o atributo OCULTO, e Get-Item SEM -Force recusa item oculto com
            # System.IO.IOException "Nao foi possivel localizar o item". Test-Path
            # (acima) enxerga o arquivo oculto, entao $temLegado ficava $true e a
            # excecao caia no catch ANTES do Remove-Item.
            #
            # MEDIDO em 27/08/2026 19:57: o cache legado nunca era removido e a
            # rotina publicava "Nenhum dos 1 arquivo(s) de cache pode ser removido:
            # todos continuam em uso" para um arquivo que nao estava em uso por
            # processo nenhum - um open exclusivo sobre ele foi concedido na
            # verificacao. Remove-Item -Force ja lidava com o atributo oculto; a
            # medicao do tamanho, imediatamente antes, e que nao lidava.
            $liberado += (Get-Item -LiteralPath $legado -Force -ErrorAction Stop).Length
            Remove-Item -LiteralPath $legado -Force -ErrorAction Stop
            $removidos++
        } catch {
            # Antes este catch era vazio: a falha do cache legado sumia.
            $bloqueados++
            [void]$nomesBloqueados.Add('IconCache.db')
            Write-Log DEBUG "Bloqueado: IconCache.db - $($_.Exception.Message)" -NoConsole
        }
    }

    # Mesma garantia de Restart-ShellExplorer: sem verificacao, uma unica tentativa
    # falha deixava o usuario sem area de trabalho e sem barra de tarefas, com o log
    # afirmando sucesso. -ErrorAction SilentlyContinue escondia ate o motivo.
    #
    # A condicao e a MESMA ja aplicada em Restart-ShellExplorer ($depois -eq 0), e
    # faltava so aqui. O Windows recoloca o shell padrao sozinho: MEDIDO em
    # 27/08/2026, o explorer.exe morto voltou como PID novo em 228 ms, muito antes
    # do fim da espera de 2 s acima. Com o shell ja de volta, Start-Process nao cria
    # processo nenhum - abre uma JANELA do Explorador de Arquivos na area de
    # trabalho do operador, que nao foi pedida por ninguem (verificado por contagem
    # de janelas do shell: 1 antes, 2 depois). A verificacao final logo abaixo
    # continua sendo feita nos dois caminhos.
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Invoke-WithRetry -Activity 'Reiniciar explorer.exe' -Retries 3 -DelaySeconds 2 -ScriptBlock {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction Stop
            Start-Sleep -Seconds 2
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { throw 'Explorer nao iniciou.' }
            $true
        } | Out-Null
    }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        $script:result = 'ERROR'
        Write-Log ERR 'O Explorer nao voltou a executar. Use Ctrl+Shift+Esc > Arquivo > Executar nova tarefa > explorer.exe'
        Add-CompartDiskFinding -Severity CRIT -Area 'Explorer' -Message 'Shell do Windows nao reiniciou apos a limpeza de cache.' -Recommendation 'Iniciar explorer.exe manualmente pelo Gerenciador de Tarefas.'
        return
    }

    # ------------------------------------------------------------ classificacao
    $status = 'OK'
    $sev    = 'OK'
    if ($totalElegiveis -eq 0) {
        $resumo = 'Nenhum arquivo elegivel: o cache ja estava vazio'
        $msg    = 'Cache de icones e miniaturas ja estava vazio: nao havia arquivo a remover.'
        Write-Log OK 'Nenhum arquivo de cache elegivel: nada a remover. O shell foi reiniciado.'
    } elseif ($bloqueados -eq 0) {
        $resumo = ("{0} de {1} arquivo(s) removido(s)" -f $removidos, $totalElegiveis)
        $msg    = "Cache de icones e miniaturas reconstruido ($removidos de $totalElegiveis arquivos)."
        Write-Log OK "$removidos arquivo(s) de cache removido(s), $(ConvertTo-CompartDiskSize $liberado) liberados."
    } elseif ($removidos -gt 0) {
        $status = 'WARN'; $sev = 'WARN'
        $script:result = 'WARN'
        $resumo = ("Parcial: {0} de {1} removido(s), {2} em uso" -f $removidos, $totalElegiveis, $bloqueados)
        $msg    = "Reconstrucao parcial do cache: $removidos de $totalElegiveis arquivos removidos; $bloqueados continuam em uso."
        Write-Log WARN "$removidos de $totalElegiveis arquivo(s) removido(s); $bloqueados continuam em uso por outro processo."
    } else {
        $status = 'WARN'; $sev = 'WARN'
        $script:result = 'WARN'
        $resumo = ("Impedida: {0} arquivo(s) elegivel(is), nenhum removido" -f $totalElegiveis)
        $msg    = "A reconstrucao do cache nao removeu nenhum dos $totalElegiveis arquivos elegiveis: todos continuam em uso."
        Write-Log WARN "Nenhum dos $totalElegiveis arquivo(s) de cache pode ser removido: todos continuam em uso."
    }

    $pares = [ordered]@{
        'Arquivos elegiveis' = $totalElegiveis
        'Arquivos removidos' = $removidos
        'Arquivos em uso'    = $bloqueados
        'Espaco liberado'    = (ConvertTo-CompartDiskSize $liberado)
    }
    if ($bloqueados -gt 0) { $pares['Em uso (nomes)'] = ((@($nomesBloqueados) | Select-Object -First 10) -join ', ') }

    Add-CompartDiskSection -Title 'Cache do Explorer' -Status $status -Summary $resumo -Pairs $pares
    Add-CompartDiskFinding -Severity $sev -Area 'Explorer' -Message $msg `
        -Recommendation $(if ($bloqueados -gt 0) { 'Arquivos mantidos abertos por outro processo (indexador, antivirus ou provedor de miniaturas). Repetir apos reiniciar o computador.' } else { '' })
}

function Reset-PrintSpooler {
    Write-Log INFO 'Limpando a fila de impressao...'
    $spool = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'

    $p = Set-CompartDiskServiceState -Name @('Spooler') -Action Stop
    if (-not $p[0].Success) {
        Write-Log WARN "Spooler nao parou: $($p[0].Detail)"
    }

    $r = Remove-CompartDiskPathSafely -Path $spool -KeepRoot
    Write-Log OK "$($r.Removed) trabalho(s) de impressao removido(s) ($(ConvertTo-CompartDiskSize $r.BytesFreed))."

    Set-CompartDiskServiceState -Name @('Spooler') -Action Start | Out-Null

    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Log OK 'Servico de spooler reiniciado com sucesso.'
        Add-CompartDiskFinding -Severity OK -Area 'Impressao' -Message "Fila de impressao limpa ($($r.Removed) trabalhos)."
    } else {
        $script:result = 'WARN'
        Write-Log WARN 'O servico de spooler nao voltou ao estado Em execucao.'
        Add-CompartDiskFinding -Severity WARN -Area 'Impressao' -Message 'Servico Spooler nao esta em execucao apos o reset.' -Recommendation 'Verificar dependencias do servico e drivers de impressora corrompidos.'
    }

    $imp = Get-CompartDiskPrinters
    if ($imp.Count -gt 0) { Add-CompartDiskSection -Title 'Impressoras' -Status INFO -Rows $imp }
}

function Reset-FolderViews {
    Write-Log INFO 'Redefinindo as preferencias de exibicao de pastas...'
    $chaves = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\Shell\BagMRU',
        'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Bags',
        'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU',
        'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
    )
    $n = 0
    foreach ($k in $chaves) {
        if (Test-Path -LiteralPath $k) {
            $r = Invoke-SafeCommand { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop } -Activity "Remover $k"
            if ($r.Success) { $n++ }
        }
    }
    Write-Log OK "$n chave(s) de exibicao removida(s). Reiniciando o shell..."
    Restart-ShellExplorer
    Add-CompartDiskFinding -Severity OK -Area 'Explorer' -Message 'Preferencias de exibicao de pastas redefinidas ao padrao.'
}

$codigo = $Global:CompartDisk.Exit.ERROR
try {
    $precisaAdmin = @('Spooler') -contains $Action
    if (-not (Start-CompartDiskModule -Name 'Explorer' -Action $Action -RequireAdmin:$precisaAdmin -Quiet:$Quiet)) {
        # Antes havia um 'exit' direto aqui. Em PowerShell o exit dispara o
        # finally, e o finally persistia $result ainda em 'OK': a acao Spooler
        # recusada por falta de privilegio saia com codigo 2 enquanto gravava
        # Resultado=OK no state_Explorer_Spooler.json. O Report.ps1 le esse
        # arquivo, entao o relatorio consolidado do Reparo Geral Automatico
        # declarava o Explorer concluido para uma etapa que nao aconteceu.
        # Mesma correcao ja aplicada em Repair.ps1, Update.ps1 e Smart.ps1.
        $result = 'ERROR'
    } else {
        switch ($Action) {
            'Restart'    { Restart-ShellExplorer }
            'ClearCache' { Clear-ShellCache }
            'Spooler'    { Reset-PrintSpooler }
            'ResetView'  { Reset-FolderViews }
        }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Explorer (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Explorer' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
    if ($null -eq $codigo) { $codigo = $Global:CompartDisk.Exit[$result] }
}
exit ([int]$codigo)
