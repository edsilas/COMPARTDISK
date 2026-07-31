<div align="center">

# COMPARTDISK

**Assistente de Reparo para Windows 10 e Windows 11**

Versão 1.2.0 · Desenvolvido por Edsilas

[Instalação](docs/INSTALACAO.md) ·
[Manual do Usuário](docs/MANUAL-DO-USUARIO.md) ·
[FAQ](docs/FAQ.md) ·
[Solução de Problemas](docs/SOLUCAO-DE-PROBLEMAS.md)

</div>

---

## O que é o COMPARTDISK

O COMPARTDISK reúne, em um único programa, as tarefas de manutenção que normalmente
exigiriam dezenas de comandos digitados à mão: reparar o Windows, consertar a
internet, liberar espaço em disco, verificar a saúde dos discos, revisar a segurança
do computador e gerar um relatório completo do estado da máquina.

Você navega por menus numerados. Escolhe uma opção, aperta a tecla, e a ferramenta
faz o resto — explicando na tela o que está acontecendo e registrando tudo em um
arquivo de log.

**Não é preciso saber programar.** Não é preciso conhecer PowerShell nem Batch.

## Principais recursos

- **Reparo automático em uma tecla** — corrige os problemas mais comuns do Windows numa sequência só.
- **Diagnóstico completo** — gera relatórios em quatro formatos (TXT, CSV, JSON e HTML) com o retrato do computador.
- **Rede e internet** — restaura conectividade, DNS, firewall e proxy.
- **Limpeza de disco** — com modo de *simulação*, que mostra quanto espaço seria liberado antes de apagar qualquer coisa.
- **Segurança** — revisa Defender, firewall, contas, BitLocker, TPM e Secure Boot.
- **Hardware e discos** — saúde física dos discos, bateria, drivers e inventário completo.
- **Funciona sem PowerShell** — se o PowerShell estiver bloqueado, cada função tem uma rotina Batch equivalente.

## Instalação rápida

1. Baixe o projeto e descompacte em uma pasta qualquer.
2. Clique com o botão direito em **`Launcher.bat`**.
3. Escolha **Executar como administrador**.

É só isso. Não há instalador, não há dependências para baixar, e nada é gravado
permanentemente no sistema. Instruções detalhadas no
[Guia de Instalação](docs/INSTALACAO.md).

## Como é a tela

```
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

## Primeiro uso recomendado

Se é a primeira vez, comece por algo que **não altera nada** no computador:

| Passo | O que fazer | Por quê |
|---|---|---|
| 1 | Menu **[8]**, opção **[2]** — Auditoria Rápida | Mostra o estado da máquina sem mexer em nada |
| 2 | Menu **[8]**, opção **[1]** — Auditoria Completa | Gera o relatório HTML completo |
| 3 | Menu **[4]**, opção **[4]** — Simular Limpeza | Mostra quanto espaço daria para liberar, sem apagar |

Só depois disso vale usar as opções que realmente modificam o sistema.

## Documentação

### Para começar

| Documento | Para quê |
|---|---|
| [Guia de Instalação](docs/INSTALACAO.md) | Baixar, descompactar e executar pela primeira vez |
| [Guia de Configuração](docs/CONFIGURACAO.md) | Onde ficam os logs, como mudar o comportamento padrão |
| [Guia de Utilização](docs/UTILIZACAO.md) | Como navegar pelos menus no dia a dia |
| [Manual do Usuário](docs/MANUAL-DO-USUARIO.md) | Explicação de cada opção, em linguagem simples |

### Referência

| Documento | Para quê |
|---|---|
| [Descrição dos Menus](docs/MENUS.md) | Mapa completo de todas as telas e opções |
| [Funcionalidades](docs/FUNCIONALIDADES.md) | O que cada recurso faz tecnicamente |
| [Requisitos do Sistema](docs/REQUISITOS.md) | O que é necessário para rodar |
| [Compatibilidade](docs/COMPATIBILIDADE.md) | Edições do Windows e comportamento em cada uma |
| [Limitações Conhecidas](docs/LIMITACOES.md) | O que a ferramenta não faz, e por quê |
| [Boas Práticas](docs/BOAS-PRATICAS.md) | Como usar com segurança |

### Suporte

| Documento | Para quê |
|---|---|
| [Perguntas Frequentes](docs/FAQ.md) | Dúvidas comuns respondidas rapidamente |
| [Solução de Problemas](docs/SOLUCAO-DE-PROBLEMAS.md) | Quando algo não funciona como esperado |

### Avançado

| Documento | Para quê |
|---|---|
| [Manual do Administrador](docs/MANUAL-DO-ADMINISTRADOR.md) | Uso em parque de máquinas, GPO, execução desassistida |
| [Manual Técnico](docs/MANUAL-TECNICO.md) | Estrutura interna, API dos módulos, como estender |
| [Arquitetura](docs/ARQUITETURA.md) | Como o Batch e o PowerShell se combinam |
| [Estrutura do Projeto](docs/ESTRUTURA.md) | O que é cada arquivo e pasta |
| [Política de Atualização](docs/ATUALIZACAO.md) | Como atualizar e o que muda entre versões |

### Projeto

| Documento | Para quê |
|---|---|
| [Histórico de Mudanças](CHANGELOG.md) | O que mudou em cada versão |
| [Licença](LICENSE) | Termos de uso e distribuição |
| [Créditos](docs/CREDITOS.md) | Autoria e reconhecimentos |

## Requisitos

- Windows 10 ou Windows 11 — edições Home, Pro, Education ou Enterprise
- Conta com privilégio de administrador
- Nenhum software adicional

O PowerShell é **opcional**. Se estiver presente, o diagnóstico é mais profundo.
Se estiver ausente ou bloqueado, todas as funções continuam disponíveis por rotinas
Batch nativas. Detalhes em [Requisitos](docs/REQUISITOS.md).

## Segurança e transparência

- Todo o código é aberto e legível — são arquivos de texto, sem binários compilados.
- Usa **apenas** componentes que já vêm no Windows. Nada é baixado da internet.
- Antes de qualquer operação destrutiva, é feito backup (arquivo `hosts`, regras de firewall, diretivas de grupo, logs de eventos).
- Operações sensíveis pedem confirmação explícita.
- Chaves de recuperação do BitLocker são exibidas na tela, mas **nunca gravadas em arquivo**.

## Licença

Distribuído sob a Licença Apache 2.0. Consulte o arquivo [LICENSE](LICENSE).

---

<div align="center">

**COMPARTDISK 1.2.0** — Desenvolvido por Edsilas

https://github.com/edsilas/compartdisk

</div>
