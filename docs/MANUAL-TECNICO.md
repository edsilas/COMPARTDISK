# Manual Técnico

**COMPARTDISK 1.3.0** · Desenvolvido por Edsilas

Para quem vai ler, manter ou estender o código.

---

## Esqueleto de um módulo

Todos os dezessete módulos de domínio seguem exatamente esta estrutura:

```powershell
<#
 COMPARTDISK 1.3.0 - Exemplo.ps1
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
| `Remove-CompartDiskPathSafely` | Lista de caminhos protegidos; nunca remove pasta do Windows, `System32` ou raiz |
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
| Código-fonte | ASCII puro, sem acentuação |
| `.ps1` | Marca de ordem de bytes UTF-8, fim de linha CRLF |
| `.bat` | **Sem** marca de ordem de bytes, fim de linha CRLF |
| Documentação | UTF-8 com acentuação |
| Identificadores PowerShell | Prefixo `CompartDisk` no substantivo |
| Variáveis de ambiente | Prefixo `COMPARTDISK_` |
| Versão | Fonte única: `$Global:CompartDisk.Version` e `%COMPARTDISK_VERSION%` |

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
