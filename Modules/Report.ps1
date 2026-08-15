<#
 COMPARTDISK 1.4.3 - Report.ps1
 Desenvolvido por Edsilas
 Acoes: Build | Consolidate | Open
 Gera relatorios TXT/CSV/JSON/HTML a partir da sessao atual ou dos estados
 persistidos pelos modulos executados anteriormente.
#>
[CmdletBinding()]
param(
    [ValidateSet('Build', 'Consolidate', 'Open')]
    [string]$Action = 'Build',
    [string]$Title = 'Relatorio consolidado de manutencao',
    [switch]$NoOpen,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

function Set-ReportResultado {
    <# O resultado do modulo escala e nunca regride: sem isso o estado final seria o
       do ultimo passo executado, e uma etapa bem-sucedida no fim apagaria a falha
       de uma etapa anterior. #>
    param([ValidateSet('OK', 'WARN', 'ERROR')][string]$Estado)
    $peso = @{ 'OK' = 0; 'WARN' = 1; 'ERROR' = 2 }
    if ($peso[$Estado] -gt $peso["$($script:result)"]) { $script:result = $Estado }
}

# Chaves cujo VALOR e material secreto. A comparacao e pelo nome COMPLETO da chave,
# nao por trecho: "Tamanho minimo da senha" (politica de contas) tem valor
# diagnostico legitimo e nao pode ser mascarado, enquanto "DefaultPassword" carrega
# a credencial em texto claro. Mascarar demais destroi o diagnostico tanto quanto
# mascarar de menos vaza segredo.
$script:PadraoChaveSensivel = '(?i)^\s*(default[_ ]?password|password|senha|token|secret|api[_ -]?key|passphrase|connection[_ ]?string|recovery[_ ]?(password|key)|numerical[_ ]?password|password[_ ]?hash|senha de recuperacao|chave de recuperacao)\s*$'

function Protect-ReportSections {
    <# Ultima barreira antes da publicacao: se algum modulo publicar material
       secreto como par chave/valor, ele nao sai daqui para TXT/CSV/JSON/HTML nem
       para o state_Report_*.json. Somente o VALOR e ocultado; a chave permanece,
       para que o relatorio continue registrando que a configuracao existe. #>
    $ocultados = 0
    foreach ($s in @($Global:CompartDisk.Sections)) {
        if (-not $s.Pairs) { continue }
        foreach ($k in @($s.Pairs.Keys)) {
            if ("$k" -match $script:PadraoChaveSensivel) {
                $s.Pairs[$k] = '[oculto pelo relatorio]'
                $ocultados++
            }
        }
    }
    if ($ocultados -gt 0) {
        Write-Log WARN "$ocultados valor(es) sensivel(is) ocultado(s) no relatorio."
        Add-CompartDiskFinding -Severity WARN -Area 'Relatorio' `
            -Message "$ocultados valor(es) potencialmente sensivel(is) foram ocultados do relatorio." `
            -Recommendation 'Revisar o modulo de origem: material secreto nao deveria chegar a um relatorio.'
        # Achado WARN sem resultado WARN e sinal mascarado. Um modulo publicando
        # segredo num relatorio e condicao relevante, mesmo com a geracao bem-sucedida.
        Set-ReportResultado 'WARN'
    }
    return $ocultados
}

function Import-SessionState {
    <# Reagrega os estados gravados por cada modulo desta sessao.

       Devolve a cobertura real da coleta, nao apenas uma contagem de arquivos: o
       relatorio precisa saber quantos modulos falharam e quantos estados nao
       puderam ser lidos para declarar "coleta completa" ou "coleta parcial". #>
    $cobertura = [pscustomobject]@{
        Arquivos      = 0
        Lidos         = 0
        Falhos        = @()
        ItensPerdidos = 0
        Modulos       = @()
        PorResultado  = [ordered]@{ 'OK' = 0; 'WARN' = 0; 'ERROR' = 0; 'UNSUPPORTED' = 0; 'Desconhecido' = 0 }
    }

    $dir = $Global:CompartDisk.OutDir
    if (-not (Test-Path -LiteralPath $dir)) { return $cobertura }

    # O proprio Report grava um state_Report_*.json contendo TUDO que acabou de
    # agregar. Reincluir esse arquivo em uma segunda consolidacao da mesma sessao
    # (cenario real: /autofix seguido do menu [8][3]) duplicaria cada achado e
    # dobraria os contadores do resumo executivo.
    $arquivos = @(Get-ChildItem -LiteralPath $dir -Filter 'state_*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'state_Report*' } | Sort-Object Name)
    $cobertura.Arquivos = $arquivos.Count
    if ($arquivos.Count -eq 0) { return $cobertura }

    $modulos = New-Object System.Collections.ArrayList
    $falhos  = New-Object System.Collections.ArrayList
    $perdidos = 0

    foreach ($f in $arquivos) {
        $j = $null
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            # Estado ilegivel e PERDA DE DADOS, nao ruido: registrado no console e
            # como achado, nunca apenas no arquivo de log.
            [void]$falhos.Add($f.Name)
            Write-Log WARN "Estado de modulo ilegivel: $($f.Name) ($($_.Exception.Message))"
            continue
        }
        if (-not $j) { [void]$falhos.Add($f.Name); Write-Log WARN "Estado de modulo vazio: $($f.Name)"; continue }

        $cobertura.Lidos++
        $res = "$($j.Result)"
        if (-not $cobertura.PorResultado.Contains($res)) { $res = 'Desconhecido' }
        $cobertura.PorResultado[$res] = 1 + [int]$cobertura.PorResultado[$res]

        [void]$modulos.Add([pscustomobject]@{
            Modulo    = $j.Module
            Resultado = $(if ("$($j.Result)") { $j.Result } else { 'Desconhecido' })
            Tempo     = "$($j.Elapsed)s"
            Executado = $j.Timestamp
            Mensagem  = $j.Message
        })

        # Cada secao e cada achado sao importados individualmente. Antes, um unico
        # item malformado (por exemplo uma severidade fora do ValidateSet) lancava e
        # o catch descartava TODAS as secoes e TODOS os achados daquele modulo.
        foreach ($s in @($j.Sections)) {
            if (-not $s) { continue }
            try {
                $pares = $null
                if ($s.Pairs) {
                    $pares = [ordered]@{}
                    foreach ($p in $s.Pairs.PSObject.Properties) { $pares[$p.Name] = $p.Value }
                }
                $st = "$($s.Status)"
                if ($st -notin @('CRIT', 'WARN', 'OK', 'INFO')) { $st = 'INFO' }
                Add-CompartDiskSection -Title "$($s.Title)" -Status $st `
                    -Summary "$($s.Summary)" -Rows @($s.Rows) -Pairs $pares
            } catch {
                $perdidos++
                Write-Log WARN "Secao ilegivel descartada em $($f.Name): $($_.Exception.Message)" -NoConsole
            }
        }
        foreach ($x in @($j.Findings)) {
            if (-not $x) { continue }
            try {
                # Severidade fora do contrato nao pode derrubar o achado inteiro nem
                # entrar crua no relatorio: vira INFO e a original fica na mensagem.
                $sev = "$($x.Severity)"
                $msg = "$($x.Message)"
                if ($sev -notin @('CRIT', 'WARN', 'OK', 'INFO')) {
                    $msg = "[severidade original '$sev'] $msg"
                    $sev = 'INFO'
                }
                Add-CompartDiskFinding -Severity $sev -Area "$($x.Area)" -Message $msg -Recommendation "$($x.Recommendation)"
            } catch {
                $perdidos++
                Write-Log WARN "Achado ilegivel descartado em $($f.Name): $($_.Exception.Message)" -NoConsole
            }
        }
    }

    $cobertura.Falhos        = @($falhos)
    $cobertura.ItensPerdidos = $perdidos
    $cobertura.Modulos       = @($modulos)

    if ($modulos.Count -gt 0) {
        Add-CompartDiskSection -Title 'Modulos executados nesta sessao' -Status INFO -Rows @($modulos) -Summary "$($modulos.Count) modulo(s)"
    }
    return $cobertura
}

function Add-ReportCoverage {
    <# Declara explicitamente se a consolidacao viu todos os modulos ou apenas parte
       deles. Um relatorio que nao diz o que ficou de fora nao permite julgar o que
       ele afirma. #>
    param([Parameter(Mandatory)]$Cobertura)

    $comErro   = [int]$Cobertura.PorResultado['ERROR']
    $ilegiveis = @($Cobertura.Falhos).Count
    $completa  = ($ilegiveis -eq 0 -and $Cobertura.ItensPerdidos -eq 0 -and $comErro -eq 0)

    $pares = [ordered]@{
        'Cobertura'                = $(if ($completa) { 'Coleta completa' } else { 'Coleta parcial' })
        'Estados encontrados'      = $Cobertura.Arquivos
        'Estados lidos'            = $Cobertura.Lidos
        'Estados ilegiveis'        = $ilegiveis
        'Itens descartados'        = $Cobertura.ItensPerdidos
        'Modulos concluidos (OK)'  = [int]$Cobertura.PorResultado['OK']
        'Modulos com atencao'      = [int]$Cobertura.PorResultado['WARN']
        'Modulos com erro'         = $comErro
        'Modulos sem suporte'      = [int]$Cobertura.PorResultado['UNSUPPORTED']
    }
    if ([int]$Cobertura.PorResultado['Desconhecido'] -gt 0) {
        $pares['Modulos sem resultado declarado'] = [int]$Cobertura.PorResultado['Desconhecido']
    }
    if ($ilegiveis -gt 0) { $pares['Arquivos ilegiveis'] = (@($Cobertura.Falhos) -join ', ') }

    Add-CompartDiskSection -Title 'Cobertura da coleta' -Status $(if ($completa) { 'OK' } else { 'WARN' }) `
        -Pairs $pares -Summary $(if ($completa) { 'Todos os estados foram lidos' } else { 'Consolidacao parcial' })

    # Modulo que falhou pode nao ter publicado achado nenhum - e justamente esse o
    # caso que some do relatorio. O resultado do modulo vira achado proprio.
    foreach ($m in @($Cobertura.Modulos)) {
        if ("$($m.Resultado)" -ne 'ERROR') { continue }
        Add-CompartDiskFinding -Severity CRIT -Area 'Relatorio' `
            -Message ("O modulo '{0}' terminou com ERRO nesta sessao{1}." -f $m.Modulo, $(if ($m.Mensagem) { ": $($m.Mensagem)" } else { '' })) `
            -Recommendation 'Reexecutar o modulo e consultar o log detalhado da sessao.'
    }
    if ($ilegiveis -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Relatorio' `
            -Message ("{0} estado(s) de modulo nao puderam ser lidos: {1}." -f $ilegiveis, (@($Cobertura.Falhos) -join ', ')) `
            -Recommendation 'O relatorio esta incompleto: reexecutar os modulos afetados.'
    }
    if ($Cobertura.ItensPerdidos -gt 0) {
        Add-CompartDiskFinding -Severity WARN -Area 'Relatorio' `
            -Message ("{0} item(ns) de secao ou achado foram descartados por formato invalido." -f $Cobertura.ItensPerdidos) `
            -Recommendation 'O relatorio esta incompleto: verificar os modulos de origem.'
    }
    if (-not $completa) { Set-ReportResultado 'WARN' }
    return $completa
}

function New-ConsolidatedReport {
    param([switch]$Consolidar)

    $cobertura = $null
    if ($Consolidar) {
        $cobertura = Import-SessionState
        Write-Log INFO ("{0} de {1} estado(s) de modulo agregado(s) a partir da sessao atual." -f $cobertura.Lidos, $cobertura.Arquivos)
    }

    # Se nao ha nada agregado, coleta um retrato minimo do sistema
    if ($Global:CompartDisk.Sections.Count -eq 0) {
        Write-Log INFO 'Nenhum estado previo encontrado. Coletando retrato do sistema...'
        Add-CompartDiskSection -Title 'Sistema operacional' -Status OK -Pairs (Get-CompartDiskSystemInfo)
        Add-CompartDiskSection -Title 'Hardware'            -Status OK -Pairs (Get-CompartDiskHardwareInfo)
        Add-CompartDiskSection -Title 'Postura de seguranca'-Status OK -Pairs (Get-CompartDiskSecurityPosture)
        Add-CompartDiskSection -Title 'Discos fisicos'      -Status OK -Rows  (Get-CompartDiskDiskInfo)
        Add-CompartDiskSection -Title 'Volumes'             -Status OK -Rows  (Get-CompartDiskVolumeInfo)
        Add-CompartDiskSection -Title 'Rede'                -Status OK -Rows  (Get-CompartDiskNetworkInfo)
        Add-CompartDiskSection -Title 'Firewall'            -Status OK -Rows  (Get-CompartDiskFirewallInfo)
        Add-CompartDiskSection -Title 'Windows Update'      -Status OK -Pairs (Get-CompartDiskWindowsUpdateInfo)
        Add-CompartDiskSection -Title 'Servicos essenciais' -Status OK -Rows  (Get-CompartDiskServiceDiagnostics)
        Add-CompartDiskSection -Title 'Licenciamento'       -Status INFO -Pairs (Get-CompartDiskLicenseInfo)
        Add-CompartDiskFinding -Severity INFO -Area 'Relatorio' -Message 'Retrato gerado sem execucao previa de modulos.' -Recommendation 'Executar a auditoria completa para um diagnostico aprofundado.'
    }

    if ($cobertura) { [void](Add-ReportCoverage -Cobertura $cobertura) }
    [void](Protect-ReportSections)

    $dados = [ordered]@{
        Meta     = New-CompartDiskReportMeta
        Sections = @($Global:CompartDisk.Sections)
        Findings = @($Global:CompartDisk.Findings)
    }

    $formatos = @('TXT', 'CSV', 'JSON', 'HTML')
    $arquivos = @()
    $r = Invoke-SafeCommand {
        New-Report -Name 'Relatorio_Consolidado' -Title $Title -Format $formatos -Data $dados -Open:(-not $NoOpen)
    } -Activity 'Geracao do relatorio consolidado' -Silent
    if ($r.Success) { $arquivos = @($r.Value) }

    # "New-Report executou" nao e prova de que houve relatorio: confirma-se arquivo
    # a arquivo, como Drivers.ps1 ja fazia. Antes, o modulo registrava
    # "Relatorio consolidado gerado (0 arquivos)" como OK e devolvia sucesso ao
    # Launcher mesmo quando nenhum formato chegou ao disco.
    $validos = New-Object System.Collections.ArrayList
    foreach ($a in $arquivos) {
        if (-not "$a") { continue }
        try {
            $fi = Get-Item -LiteralPath "$a" -ErrorAction Stop
            # PSIsContainer antes do tamanho: .Length devolve 1 para qualquer objeto
            # escalar do PowerShell, entao um diretorio no caminho do relatorio
            # passaria por arquivo valido.
            if (-not $fi.PSIsContainer -and $fi.Length -gt 0) {
                [void]$validos.Add([pscustomobject]@{ Arquivo = $fi.Name; Bytes = $fi.Length; Caminho = $fi.FullName })
            }
            else { Write-Log WARN ("Relatorio invalido ou vazio: {0}" -f $fi.FullName) }
        } catch {
            Write-Log WARN ("Relatorio declarado mas nao encontrado: {0}" -f $a) -ErrorRecord $_
        }
    }

    if (-not $r.Success) {
        Write-Log ERR 'A geracao do relatorio consolidado falhou.' -ErrorRecord $r.Error
        Add-CompartDiskFinding -Severity CRIT -Area 'Relatorio' `
            -Message ("Nao foi possivel gerar o relatorio consolidado: {0}" -f $(if ($r.Error) { $r.Error.Exception.Message } else { 'falha nao identificada' })) `
            -Recommendation 'Verificar permissoes de escrita e espaco no diretorio de saida da sessao.'
        Set-ReportResultado 'ERROR'
        return
    }
    if ($validos.Count -eq 0) {
        Write-Log ERR 'Nenhum arquivo de relatorio pode ser confirmado no disco.'
        Add-CompartDiskFinding -Severity CRIT -Area 'Relatorio' `
            -Message 'Nenhum arquivo de relatorio foi confirmado no disco apos a geracao.' `
            -Recommendation 'Verificar permissoes de escrita e espaco no diretorio de saida da sessao.'
        Set-ReportResultado 'ERROR'
        return
    }

    $crit = @($Global:CompartDisk.Findings | Where-Object { $_.Severity -eq 'CRIT' }).Count
    $warn = @($Global:CompartDisk.Findings | Where-Object { $_.Severity -eq 'WARN' }).Count
    $ok   = @($Global:CompartDisk.Findings | Where-Object { $_.Severity -eq 'OK' }).Count

    Write-Color ''
    Write-Color '  RESUMO EXECUTIVO' -Color White
    Write-Color ("    Itens criticos    : {0}" -f $crit) -Color $(if ($crit -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Color ("    Itens em atencao  : {0}" -f $warn) -Color $(if ($warn -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Color ("    Itens conformes   : {0}" -f $ok)   -Color Green
    if ($cobertura) {
        $txt = $(if ([int]$cobertura.PorResultado['ERROR'] -gt 0 -or @($cobertura.Falhos).Count -gt 0 -or $cobertura.ItensPerdidos -gt 0) { 'Coleta parcial' } else { 'Coleta completa' })
        Write-Color ("    Cobertura         : {0} ({1}/{2} estados lidos)" -f $txt, $cobertura.Lidos, $cobertura.Arquivos) `
            -Color $(if ($txt -eq 'Coleta completa') { 'DarkGray' } else { 'Yellow' })
    }
    Write-Color ''
    Write-Color '  ARQUIVOS GERADOS' -Color White
    foreach ($a in $validos) { Write-Color ("    {0}" -f $a.Caminho) -Color Cyan }

    # Formato solicitado que nao chegou ao disco e perda parcial, nao sucesso pleno.
    # O CSV e a unica ausencia legitima: nao ha o que achatar quando o relatorio
    # esta vazio de secoes e achados.
    $faltando = @($formatos | Where-Object { $f = $_; -not (@($validos) | Where-Object { $_.Arquivo -like "*.$($f.ToLowerInvariant())" }) })
    if ($faltando.Count -gt 0) {
        Write-Log WARN ("Formato(s) nao confirmado(s) no disco: {0}." -f ($faltando -join ', '))
        Add-CompartDiskFinding -Severity WARN -Area 'Relatorio' `
            -Message ("{0} de {1} formato(s) de relatorio nao foram confirmados: {2}." -f $faltando.Count, $formatos.Count, ($faltando -join ', ')) `
            -Recommendation 'Verificar permissoes de escrita no diretorio de saida da sessao.'
        Set-ReportResultado 'WARN'
    }

    if ($crit -gt 0) { Set-ReportResultado 'WARN' }
    Write-Log OK ("Relatorio consolidado gerado ({0} de {1} formato(s) confirmado(s), {2} critico(s), {3} aviso(s))." -f $validos.Count, $formatos.Count, $crit, $warn)
}

function Open-LastReport {
    $dir = $Global:CompartDisk.LogDir
    $raiz = Join-Path $dir 'COMPARTDISK_Relatorios'
    if (-not (Test-Path -LiteralPath $raiz)) {
        Write-Log WARN "Nenhum relatorio encontrado em: $raiz"
        Set-ReportResultado 'WARN'
        return
    }
    $ultimo = Get-ChildItem -LiteralPath $raiz -Recurse -Filter '*.html' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $ultimo) {
        Write-Log WARN 'Nenhum relatorio HTML localizado.'
        Set-ReportResultado 'WARN'
        return
    }
    if ($ultimo.Length -le 0) {
        Write-Log WARN "Relatorio localizado esta vazio: $($ultimo.FullName)"
        Set-ReportResultado 'WARN'
        return
    }
    Write-Log OK "Abrindo: $($ultimo.FullName)"
    # Falha ao abrir nao pode terminar como sucesso: o operador pediu para ver o
    # relatorio e nada apareceu na tela.
    $r = Invoke-SafeCommand { Start-Process $ultimo.FullName } -Activity 'Abrir relatorio' -Silent
    if (-not $r.Success) {
        Write-Log WARN ("Nao foi possivel abrir o arquivo automaticamente: {0}" -f $ultimo.FullName)
        Set-ReportResultado 'WARN'
    }
}

try {
    if (-not (Start-CompartDiskModule -Name 'Report' -Action $Action -Quiet:$Quiet)) {
        # O estado persistido vem de $result e o finally roda mesmo com este exit:
        # sair sem marcar gravava "Resultado=OK" para uma execucao recusada.
        $result = 'ERROR'
        exit $Global:CompartDisk.Exit.ERROR
    }
    switch ($Action) {
        'Build'       { New-ConsolidatedReport }
        'Consolidate' { New-ConsolidatedReport -Consolidar }
        'Open'        { Open-LastReport }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada no modulo Report (Acao=$Action)." -ErrorRecord $_
    Add-CompartDiskFinding -Severity CRIT -Area 'Relatorio' -Message "Excecao no modulo: $($_.Exception.Message)"
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
