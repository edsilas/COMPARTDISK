# Manual Técnico

**COMPARTDISK 1.4.0** · Desenvolvido por Edsilas

Para quem vai ler, manter ou estender o código.

---

## Esqueleto de um módulo

Todos os dezessete módulos de domínio seguem exatamente esta estrutura:

```powershell
<#
 COMPARTDISK 1.4.0 - Exemplo.ps1
 Desenvolvido por Edsilas
 Acoes: Acao1 | Acao2
#>
[CmdletBinding()]
param(
    [ValidateSet('Acao1', 'Acao2')]
    [string]$Action = 'Acao1',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')

$result = 'OK'

try {
    if (-not (Start-CompartDiskModule -Name 'Exemplo' -Action $Action -Quiet:$Quiet)) {
        exit $Global:CompartDisk.Exit.ERROR
    }
    switch ($Action) {
        'Acao1' { Invoke-Acao1 }
        'Acao2' { Invoke-Acao2 }
    }
} catch {
    $result = 'ERROR'
    Write-Log ERR "Falha nao tratada (Acao=$Action)." -ErrorRecord $_
} finally {
    $codigo = Stop-CompartDiskModule -Result $result -Quiet:$Quiet
}
exit $codigo
```

Pontos obrigatórios:

- `ValidateSet` no parâmetro `Action` — o Launcher depende disso para falhar cedo.
- `$ErrorActionPreference = 'Stop'` — sem isso, erros não terminantes passariam despercebidos.
- Carga do `Core.ps1` por ponto, e não por importação de módulo.
- `try` / `catch` / `finally` envolvendo toda a execução.
- `exit $codigo` — o Launcher usa o código de saída para decidir sobre o fallback.

---

## API do Core

### Registro

| Função | Uso |
|---|---|
| `Write-Log <Nivel> <Mensagem>` | Níveis: `INFO`, `OK`, `WARN`, `ERR`, `DEBUG` |
| `Write-Log ERR "..." -ErrorRecord $_` | Registra tipo, código, mensagem e pilha da exceção |
| `Write-Color`, `Write-CompartDiskKeyValue` | Saída formatada no console |
| `Write-CompartDiskBanner <Titulo>` | Cabeçalho de tela, com assinatura de autoria |

### Acúmulo de resultados

| Função | Uso |
|---|---|
| `Add-CompartDiskFinding -Severity <CRIT\|WARN\|OK\|INFO> -Area <a> -Message <m> -Recommendation <r>` | Registra uma constatação |
| `Add-CompartDiskSection -Title <t> -Status <s> -Rows <r> -Pairs <p>` | Registra uma seção de relatório |

Constatações e seções são acumuladas em memória e persistidas ao final do módulo, para
que `Report.ps1` possa agregá-las.

### Ciclo de vida

| Função | Uso |
|---|---|
| `Start-CompartDiskModule -Name <n> -Action <a>` | Marca o início, registra contexto |
| `Stop-CompartDiskModule -Result <OK\|WARN\|ERROR\|UNSUPPORTED>` | Persiste o estado e retorna o código de saída |

### Execução protegida

| Função | Uso |
|---|---|
| `Invoke-SafeCommand` | Executa um bloco capturando exceções |
| `Invoke-WithRetry` | Nova tentativa com espera progressiva |
| `Invoke-NativeCommand` | Executa programa externo capturando saída, erro e tempo limite |

### Testes de ambiente

`Test-Administrator`, `Test-PowerShell`, `Test-WindowsVersion`, `Test-Winget`,
`Test-WMI`, `Test-CIM`, `Test-TPM`, `Test-SecureBoot`, `Test-BitLocker`,
`Test-Internet`, `Get-CompartDiskCapabilities`.

### Consulta ao sistema

```powershell
Get-CompartDiskCim -Class Win32_ComputerSystem
Get-CompartDiskCim -Query 'SELECT * FROM SoftwareLicensingService'
```

Tenta CIM, depois WMI, depois CIM sobre DCOM. Por padrão não lança exceção — retorna
vazio, o que mantém a coleta funcionando em máquinas com WMI degradado.

### Utilitários protegidos

| Função | Proteção |
|---|---|
| `Remove-CompartDiskPathSafely` | Lista de caminhos protegidos, comparada por **igualdade exata** após normalização: recusa a raiz da unidade, a pasta do Windows, `System32` e `Program Files`. Não é hierárquica — subpastas como `System32\GroupPolicy` são removíveis, e o reset de diretivas depende disso |
| `Set-CompartDiskRegistryValue` | Idempotente; registra o valor anterior |
| `Set-CompartDiskServiceState` | Trata serviço inexistente sem lançar exceção |

### Relatórios

`New-Report -Name <n> -Title <t> -Format TXT,CSV,JSON,HTML -Data <d>`

---

## Coletores

`Collectors.ps1` reúne as funções de leitura. **Nenhuma altera o sistema.** São
carregadas automaticamente pelo `Core.ps1`.

Principais: `Get-CompartDiskSystemInfo`, `Get-CompartDiskHardwareInfo`,
`Get-CompartDiskDiskInfo`, `Get-CompartDiskVolumeInfo`, `Get-CompartDiskNetworkInfo`,
`Get-CompartDiskSecurityPosture`, `Get-CompartDiskDefenderStatus`,
`Get-CompartDiskWindowsUpdateInfo`, `Get-CompartDiskDriverInfo`,
`Get-CompartDiskEventSummary`, `Get-CompartDiskLocalUsers`,
`Get-CompartDiskLicenseInfo`, `Get-CompartDiskInstalledSoftware`.

Essa separação é o que garante que uma auditoria jamais altere o sistema, e evita
duplicação entre os módulos.

---

## Como adicionar uma funcionalidade

1. **Escreva a ação no módulo de domínio** correspondente, acrescentando o nome ao
   `ValidateSet`.
2. **Acrescente o rótulo `:MOD_*` no Launcher**, seguindo o padrão de invocação.
3. **Escreva a rotina `:FB_*` correspondente.** Obrigatório. Um módulo sem rotina de
   contingência viola o princípio central do projeto.
4. **Acrescente a opção ao menu**, ajustando a sequência do `choice` e a cadeia de
   `if errorlevel`.
5. **Atualize a documentação**: [Menus](MENUS.md), [Funcionalidades](FUNCIONALIDADES.md)
   e [Manual do Usuário](MANUAL-DO-USUARIO.md).

### Cadeia do `choice`

A verificação de `errorlevel` é **maior ou igual**, por isso a cadeia é escrita em
ordem decrescente:

```bat
choice /c 1234567890 /n /m "Opcao: "
if errorlevel 10 goto MENU_PRINCIPAL
if errorlevel 9 call :MOD_NOVA_OPCAO
...
if errorlevel 1 call :MOD_PRIMEIRA
```

A posição no `/c` determina o `errorlevel`. Acrescentar uma opção exige inserir o
dígito na sequência **e** deslocar a cadeia.

---

## Armadilhas do interpretador de comandos

Problemas reais já enfrentados neste projeto, documentados para não se repetirem.

### Expansão percentual acontece antes dos operadores

```bat
echo %MSG%
```

Se `MSG` contiver `|`, o interpretador cria um encadeamento de comandos. Foi a causa
de um log que ficava vazio. `DisableDelayedExpansion` protege contra `!`, **não**
contra `|`, `&`, `<` e `>`. A rotina `:LOG_MSG` higieniza esses caracteres na origem.

### `net session` não é teste de privilégio

Falha quando o serviço *Server* está parado. Use `fltmc`.

### Aninhamento de aspas

Argumentos para os módulos trafegam pela variável `PS_ARGS`, e não como parâmetro
direto, justamente para evitar isso.

### `FOR /F` com caminho entre aspas

O parser é instável nesse caso. A geração do identificador de sessão usa arquivo
temporário e `set /p`.

### Rótulo inexistente encerra o script

Um `goto` para rótulo que não existe termina a execução imediatamente, sem mensagem
útil. É por isso que existe o trace de inicialização.

### Parênteses dentro de blocos

Dentro de um bloco `( ... )`, um `)` não escapado encerra o bloco. Em `echo`, escreva
`^(` e `^)`.

---

## Convenções de codificação

| Item | Regra |
|---|---|
| Código-fonte | ASCII puro, sem acentuação. Exceção única: o travessão do título oficial da janela, em `Launcher.bat`, que só é decodificado corretamente porque `chcp 65001` executa antes — há variante ASCII automática se a troca de página de código falhar |
| `.ps1` | Marca de ordem de bytes UTF-8, fim de linha CRLF |
| `remote.ps1` | **Sem** marca de ordem de bytes, fim de linha CRLF. É baixado e avaliado por `iex`, e o BOM chega como `U+FEFF` no início da cadeia, impedindo o parser de reconhecer a abertura de comentário da linha 1 |
| `.bat` | **Sem** marca de ordem de bytes, fim de linha CRLF |
| Documentação | UTF-8 com acentuação |
| Identificadores PowerShell | Prefixo `CompartDisk` no substantivo |
| Variáveis de ambiente | Prefixo `COMPARTDISK_` |
| Versão | Fonte única: `$Global:CompartDisk.Version` e `%COMPARTDISK_VERSION%` |

---

## Estendendo o catálogo do Debloat

`Debloat.ps1` e `Apps.ps1` são os módulos com catálogo declarativo. Adicionar um item
não exige tocar em lógica alguma: basta acrescentar uma entrada na lista correspondente
dentro de `Get-DebloatCatalogo`.

```powershell
$servicos = @(
    @{ N = 'NomeDoServico'; Startup = 'Disabled'; L = 'Moderate'; M = 'Motivo tecnico.' }
)
```

| Campo | Significado |
|---|---|
| `N` | Nome do alvo |
| `L` | Nível mínimo em que passa a ser elegível |
| `M` | Motivo técnico, exibido no relatório |
| `Startup` | Apenas para serviços: tipo de inicialização de destino |
| `P` `V` | Apenas para registro: caminho da chave e valor de destino |

**Use sempre tabelas de dispersão com chaves nomeadas, nunca arrays posicionais.** O
PowerShell achata arrays aninhados separados por quebra de linha dentro de `@()`:

```powershell
$x = @( @('a','b')
        @('c','d') )   # resulta em 4 elementos, nao 2
```

O acesso por índice passa então a indexar a cadeia de caracteres, e o erro aparece longe
da causa. Com chaves nomeadas o problema não existe.

**Depois de adicionar um item**, confirme que ele não colide com as listas de proteção:

```powershell
. .\Modules\Debloat.ps1 -Action Analyze -Level Aggressive
```

---

## Estendendo o catálogo de aplicativos

`Apps.ps1` mantém o catálogo de instalação em `$script:Catalogo`. Menus, numeração,
lote, instalação global e verificação são derivados dele — incluir uma ferramenta é
acrescentar uma entrada, sem tocar em lógica de menu.

```powershell
[pscustomobject]@{ Name = 'HWiNFO'; Id = 'REALiX.HWiNFO'; Category = 'Hardware'
    Description = 'Diagnostico e inventario detalhado de hardware'
    Native = $false; Available = $true; Publisher = 'REALiX'; PackageType = 'inno'
    Scope = 'machine'; Architecture = 'x64, arm64'; SuiteId = $null; Note = '' }
```

| Campo | Significado |
|---|---|
| `Name` `Id` `Category` `Description` | Obrigatórios. `Id` é o identificador exato do Winget |
| `Native` | `$true` quando o recurso já acompanha o Windows — nada é instalado |
| `Available` | `$false` quando não existe pacote na fonte oficial. Nesse caso `Id` fica vazio |
| `Publisher` `PackageType` `Scope` `Architecture` | Metadados conferidos no manifesto oficial |
| `SuiteId` | Pacote que já contém a ferramenta; evita download redundante |
| `Note` | Texto exibido quando o item não é instalável |

**O identificador precisa ser conferido no catálogo oficial antes de entrar aqui.**
Nunca deduza um `Id`: confirme-o na fonte `winget` e registre o editor, o tipo de
instalador e a arquitetura como publicados no manifesto. Item sem pacote válido entra
com `Available = $false` e `Note` explicando — nunca com URL substituta.

A rotina Batch de contingência (`:FB_APPS_WALK1` a `:FB_APPS_WALK6`, em
`Launcher.bat`) espelha esse catálogo com os mesmos identificadores e a mesma ordem.
Ao acrescentar um aplicativo, acrescente a linha equivalente na categoria
correspondente, sob pena de o caminho sem PowerShell ficar defasado.

Um item protegido nunca aparece na simulação, por desenho.

---

## Verificações antes de publicar

- Nenhuma referência residual a nome ou versão anteriores.
- Todos os rótulos referenciados no Launcher existem.
- Parênteses e aspas balanceados, com profundidade final zero.
- Toda ação invocada existe no `ValidateSet` do módulo alvo.
- Toda função chamada está definida.
- `.bat` sem marca de ordem de bytes e iniciando em `@echo off`.
- Cada `:MOD_*` possui a rotina `:FB_*` correspondente.

---

[Voltar ao índice](../README.md) · Próximo: [FAQ](FAQ.md)
