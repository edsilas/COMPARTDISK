# Guia de Execução Remota

**COMPARTDISK 1.3.0** · Desenvolvido por Edsilas

Executa a versão estável mais recente com um único comando, sem download manual e
sem verificar atualizações.

---

## 1. O comando

Abra o **PowerShell como administrador** e execute:

```powershell
irm https://raw.githubusercontent.com/edsilas/compartdisk/main/remote.ps1 | iex
```

> [!IMPORTANT]
> É necessário abrir o PowerShell **como administrador**. Clique com o botão direito
> no menu Iniciar e escolha **Terminal (Admin)** no Windows 11, ou
> **Windows PowerShell (Admin)** no Windows 10.

Se a sessão não tiver privilégio administrativo, o script avisa e encerra **sem
alterar nada** no sistema.

### O que o comando faz

`irm` é a abreviação de `Invoke-RestMethod`, que baixa o conteúdo do endereço.
`iex` é `Invoke-Expression`, que executa esse conteúdo. Juntos, buscam o
inicializador do projeto e o executam na memória, sem gravar nada em disco.

---

## 2. O que acontece, passo a passo

| Etapa | Ação |
|---|---|
| 1 | Ajusta o protocolo TLS para 1.2 ou superior |
| 2 | Verifica se a sessão tem privilégio administrativo |
| 3 | Testa a conexão com o GitHub |
| 4 | Consulta qual é a versão estável mais recente |
| 5 | Baixa o pacote da versão para uma pasta temporária |
| 6 | Valida a integridade do arquivo |
| 7 | Extrai e confere se o conteúdo está completo |
| 8 | Executa o `Launcher.bat` — os mesmos menus da instalação local |
| 9 | Ao sair, remove todos os arquivos temporários |

Nada permanece no disco após o encerramento.

---

## 3. Validação de integridade

O inicializador valida o pacote em duas camadas antes de executar qualquer coisa.

**Assinatura de arquivo.** Confere se os primeiros bytes correspondem a um arquivo
ZIP válido. Isso detecta download interrompido ou conteúdo substituído por uma
página de erro de proxy corporativo.

**Impressão digital SHA-256.** As notas de cada versão publicam o valor SHA-256 do
pacote. O inicializador extrai esse valor e o compara com o arquivo baixado. Se não
conferir, a execução é interrompida.

**Verificação estrutural.** Após extrair, confirma que existem o `Launcher.bat` e a
pasta `Modules` com a biblioteca central. Um pacote incompleto não é executado.

> [!NOTE]
> Se uma versão não publicar o SHA-256 nas notas, o script informa que a validação
> de hash está indisponível e prossegue com as demais verificações. Ele nunca falha
> em silêncio.

---

## 4. Tratamento de erros

| Situação | Comportamento |
|---|---|
| Sem conexão com a internet | Informa e sugere baixar o pacote manualmente |
| Proxy ou firewall bloqueando | Detectado no teste de conectividade, com orientação |
| Falha momentânea de rede | Três tentativas automáticas, com espera progressiva |
| Download corrompido | Recusado pela assinatura de arquivo |
| Pacote adulterado | Recusado pela verificação SHA-256 |
| Conteúdo incompleto | Recusado pela verificação estrutural |
| Sem privilégio administrativo | Avisa e encerra sem alterar nada |

Em qualquer falha, o script exibe três alternativas: baixar manualmente, verificar
proxy e firewall, ou relatar o problema.

---

## 5. Comparação com a instalação local

Os dois métodos executam **exatamente o mesmo programa**, com os mesmos menus,
módulos e fluxos.

| Aspecto | Execução remota | Instalação local |
|---|---|---|
| Versão executada | Sempre a mais recente | A que você baixou |
| Ocupa espaço em disco | Não, é removido ao sair | Sim, cerca de 2 MB |
| Precisa de internet | Sim, a cada execução | Apenas para baixar |
| Relatórios gerados | Sim, na pasta de log habitual | Sim |
| Funciona offline | Não | Sim |
| Indicado para | Uso pontual, suporte técnico | Uso recorrente, parque de máquinas |

> [!TIP]
> Se você usa a ferramenta com frequência, ou se a máquina tem acesso limitado à
> internet, prefira a instalação local. Consulte o
> [Guia de Instalação](INSTALACAO.md).

---

## 6. Configuração avançada

O comportamento pode ser ajustado por variáveis de ambiente, definidas **antes** do
comando.

### Fixar uma versão específica

Útil para reproduzir um cenário ou padronizar um parque de máquinas:

```powershell
$env:COMPARTDISK_TAG = 'v1.2.0'
irm https://raw.githubusercontent.com/edsilas/compartdisk/main/remote.ps1 | iex
```

### Usar um espelho interno

Para organizações que mantêm uma cópia do repositório:

```powershell
$env:COMPARTDISK_REPO = 'minhaempresa/compartdisk'
irm https://raw.githubusercontent.com/minhaempresa/compartdisk/main/remote.ps1 | iex
```

| Variável | Efeito | Padrão |
|---|---|---|
| `COMPARTDISK_TAG` | Executa a versão indicada em vez da mais recente | vazio |
| `COMPARTDISK_REPO` | Repositório de origem | `edsilas/compartdisk` |

---

## 7. Perguntas frequentes

**É seguro executar um script direto da internet?**

A pergunta é correta e vale para qualquer comando nesse formato. Antes de executar,
você pode ler o código-fonte:
[remote.ps1](https://github.com/edsilas/compartdisk/blob/main/remote.ps1). São
cerca de 350 linhas comentadas em português. O script não coleta dados, não faz
conexões além do GitHub e remove tudo que baixou ao encerrar.

**Preciso alterar a política de execução do PowerShell?**

Não. O conteúdo é executado na memória por `Invoke-Expression`, o que não está
sujeito à política de execução de arquivos.

**Funciona em rede corporativa com proxy?**

Depende da política. Se o proxy exigir autenticação ou bloquear o GitHub, o script
detecta a falha e orienta o download manual.

**Consome mais internet a cada execução?**

Sim: o pacote, de cerca de 2 MB, é baixado toda vez. Para uso recorrente, a
instalação local é mais eficiente.

**O antivírus pode bloquear?**

Pode. Ferramentas de manutenção que alteram rede e registro são monitoradas por
padrão. O código é aberto e auditável.

---

## 8. Referência do arquivo

O inicializador fica em `remote.ps1`, na raiz do repositório. Ele é
**apenas um método adicional de partida**: não altera, substitui nem contorna
nenhum fluxo do projeto. Ao final, entrega o controle ao `Launcher.bat` da
distribuição oficial.

Estrutura interna:

| Função | Responsabilidade |
|---|---|
| `Initialize-Tls` | Força TLS 1.2 ou superior |
| `Test-Conectividade` | Verifica se o GitHub está acessível |
| `Invoke-ComRetentativa` | Repete operações de rede com espera progressiva |
| `Get-HashPublicado` | Extrai o SHA-256 das notas da versão |
| `Get-VersaoMaisRecente` | Consulta a versão estável mais recente |
| `Get-Pacote` | Baixa o pacote e valida o tamanho |
| `Test-Integridade` | Confere assinatura de arquivo e SHA-256 |
| `Expand-Pacote` | Extrai e verifica se o conteúdo está completo |
| `Test-Administrador` | Verifica o privilégio da sessão |

---

[Voltar ao índice](../README.md) · Relacionado: [Guia de Instalação](INSTALACAO.md)
