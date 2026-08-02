# COMPARTDISK

<p align="left">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-Apache%202.0-0078D4?style=flat-square&logo=apache&logoColor=white" alt="License">
  </a>
  <a href="CHANGELOG.md">
    <img src="https://img.shields.io/badge/Release-v1.2.0-107C10?style=flat-square&logo=github&logoColor=white" alt="Release">
  </a>
  <a href="#3-pré-requisitos">
    <img src="https://img.shields.io/badge/Platform-Windows-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Platform">
  </a>
  <a href="#3-pré-requisitos">
    <img src="https://img.shields.io/badge/Shell-PowerShell%205.1%20%7C%207-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell">
  </a>
</p>

**Assistente de Reparo para Windows**

Ferramenta de manutenção que reúne, em menus numerados, as tarefas de reparo,
limpeza, diagnóstico e verificação de segurança do Windows. Usa exclusivamente
componentes nativos do sistema operacional, sem instalação e sem dependências.
Compatível atualmente com Windows 10 e Windows 11.

> Desenvolvido por Edsilas

---

## Índice

| Seção | Conteúdo |
|---|---|
| [1. Visão geral](#1-visão-geral) | O que a ferramenta faz e a quem se destina |
| [2. Recursos](#2-recursos) | Capacidades principais |
| [3. Pré-requisitos](#3-pré-requisitos) | O que é necessário antes de começar |
| [4. Início rápido](#4-início-rápido) | Executar em um comando ou instalar localmente |
| [5. Interface](#5-interface) | Como a ferramenta se apresenta |
| [6. Uso avançado](#6-uso-avançado) | Execução desassistida e parque de máquinas |
| [7. Segurança e privacidade](#7-segurança-e-privacidade) | O que a ferramenta faz e não faz com seus dados |
| [8. Documentação](#8-documentação) | Índice completo dos guias e manuais |
| [9. Solução de problemas](#9-solução-de-problemas) | Primeiros passos quando algo falha |
| [10. Contribuindo](#10-contribuindo) | Como relatar problemas e sugerir melhorias |
| [11. Licença](#11-licença) | Termos de uso e distribuição |
| [12. Marcas registradas](#12-marcas-registradas) | Avisos legais |

---

## 1. Visão geral

O COMPARTDISK reúne, em um único programa, as tarefas de manutenção que normalmente
exigiriam dezenas de comandos digitados à mão: reparar o Windows, consertar a
internet, liberar espaço em disco, verificar a saúde dos discos, revisar a segurança
do computador e gerar um relatório completo do estado da máquina.

Você navega por menus numerados. Escolhe uma opção, aperta a tecla, e a ferramenta
faz o resto — explicando na tela o que está acontecendo e registrando tudo em um
arquivo de log.

### A quem se destina

| Perfil | Como a ferramenta ajuda |
|---|---|
| **Usuário doméstico** | Resolve problemas comuns sem precisar pesquisar comandos ou seguir tutoriais |
| **Técnico de suporte** | Padroniza o diagnóstico e gera um relatório anexável ao chamado |
| **Administrador de TI** | Executa auditorias desassistidas em parque de máquinas, com saída em CSV e JSON |

> [!NOTE]
> Não é preciso saber programar. Não é preciso conhecer PowerShell nem Batch.

### Arquitetura em uma frase

O arquivo `Launcher.bat` concentra a interface e o controle de fluxo; os módulos
PowerShell executam as operações complexas. Quando o PowerShell está ausente ou
bloqueado por política, cada função recorre a uma rotina Batch equivalente — nenhuma
funcionalidade deixa de existir. Detalhes em [Arquitetura](docs/ARQUITETURA.md).

---

## 2. Recursos

| Recurso | Descrição |
|---|---|
| **Reparo automático** | Corrige em sequência os problemas mais comuns do Windows, com uma única tecla |
| **Diagnóstico completo** | Gera o retrato da máquina em quatro formatos: TXT, CSV, JSON e HTML |
| **Rede e internet** | Restaura conectividade, DNS, Winsock, firewall e proxy |
| **Limpeza de disco** | Inclui modo de simulação, que mede o espaço recuperável antes de apagar |
| **Segurança** | Revisa Defender, firewall, contas, BitLocker, TPM e Secure Boot |
| **Hardware e discos** | Saúde física dos discos, desgaste da bateria, drivers e inventário completo |
| **Operação sem PowerShell** | Cada função possui rotina Batch equivalente para ambientes restritos |
| **Execução remota** | Um único comando executa a versão mais recente, com validação de integridade |

---

## 3. Pré-requisitos

### Sistema operacional

- Windows — compatível atualmente com Windows 10 (versão 1809 ou superior) e Windows 11
- Edições Home, Pro, Education ou Enterprise
- Arquitetura x64 ou ARM64

### Permissões

- Conta com privilégio de administrador

A ferramenta solicita a elevação automaticamente ao iniciar. Sem privilégio
administrativo, o Windows recusaria a maior parte das operações.

### Componentes opcionais

Nenhum é obrigatório. A ausência de qualquer um reduz a profundidade do diagnóstico,
mas **não remove funcionalidades**.

| Componente | Se presente | Se ausente |
|---|---|---|
| Windows PowerShell 5.1 | Diagnóstico completo e relatórios nos quatro formatos | Rotinas Batch assumem |
| PowerShell 7 | O mesmo, com melhor desempenho | O PowerShell 5.1 é utilizado |
| Winget | Atualização de programas instalados | A opção informa indisponibilidade |
| PnPUtil | Backup e inventário de drivers | A opção informa indisponibilidade |

> [!TIP]
> Para verificar o que foi detectado na sua máquina, abra a opção **[9] Ambiente de
> Execução e Capacidades** no menu principal.

Detalhes completos em [Requisitos do Sistema](docs/REQUISITOS.md) e
[Compatibilidade](docs/COMPATIBILIDADE.md).

---

## 4. Início rápido

Há dois métodos de execução. Ambos rodam **o mesmo programa**, com os mesmos menus,
módulos e fluxos.

### Método A — Execução remota (um comando)

Sempre executa a versão estável mais recente, sem download manual e sem verificar
atualizações. Abra o **PowerShell como administrador** e execute:

```powershell
irm https://raw.githubusercontent.com/edsilas/compartdisk/main/remote.ps1 | iex
```

O inicializador consulta a versão mais recente, baixa o pacote, **valida a
integridade por SHA-256** e executa o `Launcher.bat`. Ao encerrar, remove todos os
arquivos temporários — nada permanece no disco.

> [!TIP]
> Indicado para uso pontual e atendimento de suporte. Para uso recorrente ou em
> máquinas com internet limitada, prefira o método B.

Detalhes, validação de integridade e configuração avançada em
[Guia de Execução Remota](docs/EXECUCAO-REMOTA.md).

### Método B — Instalação local

#### Passo 1 — Baixar e extrair

1. Baixe o pacote mais recente em [Releases](https://github.com/edsilas/compartdisk/releases/latest).
2. Clique com o botão direito no arquivo `.zip`, selecione **Propriedades**, marque
   **Desbloquear** e clique em **OK**.
3. Extraia o conteúdo para uma pasta, por exemplo `C:\COMPARTDISK`.

> [!IMPORTANT]
> Não execute a ferramenta de dentro do arquivo compactado. O Windows abre o
> conteúdo em uma pasta temporária somente leitura, e os relatórios não poderão ser
> gravados.

#### Passo 2 — Executar

1. Clique com o botão direito em **`Launcher.bat`**.
2. Selecione **Executar como administrador**.
3. Confirme a solicitação do Controle de Conta de Usuário.

Não há instalador, dependências para baixar ou alterações permanentes no sistema.
Para desinstalar, apague a pasta.

#### Passo 3 — Primeiro diagnóstico

Comece por operações que **não alteram nada** no computador:

| Ordem | Caminho | Resultado |
|---|---|---|
| 1 | Menu **[9]** | Mostra o que a ferramenta detectou no seu Windows |
| 2 | Menu **[8]** → opção **[2]** | Auditoria rápida, em menos de um minuto |
| 3 | Menu **[8]** → opção **[1]** | Auditoria completa, com relatório HTML |
| 4 | Menu **[4]** → opção **[4]** | Simula a limpeza e mede o espaço recuperável |

Somente depois disso vale usar as opções que modificam o sistema.

Instruções detalhadas em [Guia de Instalação](docs/INSTALACAO.md).

### Qual método usar

| Critério | Execução remota | Instalação local |
|---|---|---|
| Versão executada | Sempre a mais recente | A que você baixou |
| Ocupa espaço em disco | Não | Cerca de 2 MB |
| Funciona sem internet | Não | Sim |
| Indicado para | Uso pontual, suporte técnico | Uso recorrente, parque de máquinas |

---

## 5. Interface

```text
  COMPARTDISK  1.2.0
  Assistente de Reparo

  --------------------------------------------------------------------------

   [1]  Reparo Geral Automatico (One-Click Fix)
   [2]  Atualizar Programas (Winget)
   [3]  Rede, Internet e Conectividade
   [4]  Otimizacao, Limpeza Profunda e Privacidade
   [5]  Reparo do Sistema, Windows Update e Explorer
   [6]  Contas, Permissoes e Seguranca
   [7]  Discos, Drivers e Auditoria de Hardware
   [8]  Diagnostico Avancado e Relatorios (TXT/CSV/JSON/HTML)
   [9]  Ambiente de Execucao e Capacidades

   [0]  Sair e Salvar Relatorio

  --------------------------------------------------------------------------
  Motor: Windows PowerShell 5.1
  Log:   C:\COMPARTDISK\Relatorio_Manutencao.txt
  DESENVOLVIDO POR EDSILAS

  Opcao:
```

A navegação é feita por teclas numéricas, sem necessidade de pressionar Enter. A
tecla `0` retorna à tela anterior. O rodapé indica qual motor está em uso e onde o
registro está sendo gravado.

Mapa completo das telas em [Descrição dos Menus](docs/MENUS.md).

---

## 6. Uso avançado

### Parâmetros de linha de comando

```bat
Launcher.bat /autofix    :: reparo geral automático e encerra
Launcher.bat /audit      :: auditoria completa com os quatro relatórios
Launcher.bat /report     :: consolida e gera apenas os relatórios
Launcher.bat /clean      :: limpeza profunda
Launcher.bat /?          :: exibe a ajuda
```

Em modo desassistido não há menus nem pausas. O processo encerra com código de saída
`0` (sucesso), `1` (avisos) ou `2` (erro tratado), o que permite encadeamento em
scripts.

### Coleta centralizada

```bat
set "COMPARTDISK_LOGDIR=\\servidor\inventario\%COMPUTERNAME%\"
\\servidor\ferramentas\compartdisk\Launcher.bat /audit
```

Cada máquina grava em sua própria subpasta. Os arquivos `.csv` e `.json` são
destinados a consumo automatizado; no JSON, filtre `Findings` por
`Severity = "CRIT"` para identificar as máquinas que exigem atenção.

Orientações completas em [Manual do Administrador](docs/MANUAL-DO-ADMINISTRADOR.md).

---

## 7. Segurança e privacidade

### Transparência

- Todo o código é aberto e legível: são arquivos de texto, sem binários compilados.
- Utiliza **apenas** componentes que já acompanham o Windows. Nada é baixado da internet.
- Não cria serviços, tarefas agendadas próprias ou entradas de inicialização.
- Não permanece em execução após ser fechada.

### Proteções

- Antes de operações destrutivas é feito backup automático: arquivo `hosts`, regras
  de firewall, diretivas de grupo e logs de eventos.
- Operações sensíveis exigem confirmação explícita.
- A remoção de arquivos recusa caminhos críticos do sistema.

### Dados nos relatórios

Os relatórios contêm nome do computador, nome de usuário, número de série do
equipamento, configuração de rede e lista de programas instalados. **Não** contêm
senhas, arquivos pessoais ou histórico de navegação.

> [!WARNING]
> Chaves de recuperação do BitLocker podem ser exibidas na tela quando solicitadas,
> mas **nunca são gravadas em arquivo**. Trate os relatórios conforme a política de
> classificação de informação da sua organização.

---

## 8. Documentação

### Introdução

| Documento | Conteúdo |
|---|---|
| [Guia de Instalação](docs/INSTALACAO.md) | Baixar, descompactar e executar pela primeira vez |
| [Guia de Execução Remota](docs/EXECUCAO-REMOTA.md) | Executar em um comando, sempre na versão mais recente |
| [Guia de Configuração](docs/CONFIGURACAO.md) | Onde ficam os logs e como ajustar o comportamento padrão |
| [Guia de Utilização](docs/UTILIZACAO.md) | Como navegar pelos menus no dia a dia |
| [Manual do Usuário](docs/MANUAL-DO-USUARIO.md) | Explicação de cada opção, em linguagem simples |

### Referência

| Documento | Conteúdo |
|---|---|
| [Descrição dos Menus](docs/MENUS.md) | Mapa completo de todas as telas e opções |
| [Funcionalidades](docs/FUNCIONALIDADES.md) | Descrição técnica de cada recurso |
| [Requisitos do Sistema](docs/REQUISITOS.md) | O que é necessário para executar |
| [Compatibilidade](docs/COMPATIBILIDADE.md) | Edições do Windows e comportamento em cada uma |
| [Limitações Conhecidas](docs/LIMITACOES.md) | O que a ferramenta não faz, e por quê |
| [Boas Práticas](docs/BOAS-PRATICAS.md) | Como utilizar com segurança |

### Suporte

| Documento | Conteúdo |
|---|---|
| [Perguntas Frequentes](docs/FAQ.md) | Dúvidas comuns respondidas de forma objetiva |
| [Solução de Problemas](docs/SOLUCAO-DE-PROBLEMAS.md) | Diagnóstico organizado por sintoma |

### Avançado

| Documento | Conteúdo |
|---|---|
| [Manual do Administrador](docs/MANUAL-DO-ADMINISTRADOR.md) | Parque de máquinas, GPO e execução desassistida |
| [Manual Técnico](docs/MANUAL-TECNICO.md) | Estrutura interna, API dos módulos e como estender |
| [Arquitetura](docs/ARQUITETURA.md) | Como o Batch e o PowerShell se combinam |
| [Estrutura do Projeto](docs/ESTRUTURA.md) | Função de cada arquivo e pasta |
| [Política de Atualização](docs/ATUALIZACAO.md) | Como atualizar e o que muda entre versões |

### Projeto

| Documento | Conteúdo |
|---|---|
| [Histórico de Mudanças](CHANGELOG.md) | O que mudou em cada versão |
| [Licença](LICENSE) | Termos de uso e distribuição |
| [Créditos](docs/CREDITOS.md) | Autoria e reconhecimentos |

---

## 9. Solução de problemas

| Sintoma | Primeira verificação |
|---|---|
| A janela abre e fecha imediatamente | Consulte `%TEMP%\COMPARTDISK_Bootstrap.log`; a última linha indica o estágio em que a inicialização parou |
| Aparece "O Windows protegeu o computador" | É o SmartScreen. Clique em **Mais informações** e depois em **Executar assim mesmo** |
| O rodapé indica "Motor: Batch" | O PowerShell está indisponível ou bloqueado. Todas as funções continuam acessíveis |
| Uma opção informa "recurso não suportado" | O hardware ou a edição do Windows não possui aquele recurso |
| A tela parece travada | Reparo profundo e varreduras levam de 15 minutos a 4 horas, sem exibir progresso |
| A execução remota falha ao baixar | Verifique proxy e firewall; o script exibe a causa e as alternativas |

Guia completo em [Solução de Problemas](docs/SOLUCAO-DE-PROBLEMAS.md).

---

## 10. Contribuindo

Relatos de problema, sugestões e melhorias são bem-vindos em
[Issues](https://github.com/edsilas/compartdisk/issues).

Ao relatar um problema, inclua:

1. A versão da ferramenta (visível no menu **[9]**)
2. A edição e a versão do Windows
3. O arquivo `%TEMP%\COMPARTDISK_Bootstrap.log`
4. O relatório HTML, se for possível gerá-lo

---

## 11. Licença

Distribuído sob a Licença Apache 2.0. Consulte o arquivo [LICENSE](LICENSE) para os
termos completos.

---

## 12. Marcas registradas

Windows, Windows 10, Windows 11, PowerShell, Microsoft Defender e BitLocker são
marcas registradas da Microsoft Corporation. Este projeto não é afiliado,
patrocinado ou endossado pela Microsoft.

---

<div align="center">

**COMPARTDISK 1.2.0** — Desenvolvido por Edsilas

https://github.com/edsilas/compartdisk

</div>
