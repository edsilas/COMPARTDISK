# Estrutura do Projeto

**COMPARTDISK 1.4.2** · Desenvolvido por Edsilas

---

## Árvore de arquivos

```
compartdisk/
├── Launcher.bat                      Programa principal
├── remote.ps1                        Inicializador de execução remota
├── README.md                         Apresentação e índice
├── CHANGELOG.md                      Histórico de versões
├── LICENSE                           Licença MIT
├── .gitignore                        Arquivos ignorados pelo controle de versão
│
├── Modules/                          Motor PowerShell (19 arquivos)
│   ├── Core.ps1                      Biblioteca central
│   ├── Collectors.ps1                Coletores de dados (somente leitura)
│   ├── Network.ps1                   Rede e conectividade
│   ├── Repair.ps1                    Reparo de arquivos e disco
│   ├── Update.ps1                    Windows Update
│   ├── Defender.ps1                  Microsoft Defender
│   ├── Cleanup.ps1                   Limpeza de disco
│   ├── Security.ps1                  Postura de segurança e permissões
│   ├── Users.ps1                     Contas locais
│   ├── Telemetry.ps1                 Telemetria
│   ├── Debloat.ps1                   Desbloat: aplicativos, servicos, tarefas, componentes
│   ├── Performance.ps1               Energia e desempenho
│   ├── Hardware.ps1                  Inventário de hardware
│   ├── Drivers.ps1                   Drivers
│   ├── Smart.ps1                     Saúde de discos e volumes
│   ├── Battery.ps1                   Bateria e energia
│   ├── Bitlocker.ps1                 Criptografia de disco
│   ├── Explorer.ps1                  Explorer, ícones e impressão
│   ├── Apps.ps1                      Catálogo e instalação de aplicativos (Winget)
│   ├── Winget.ps1                    Diagnóstico e preparação do ambiente WinGet
│   ├── Audit.ps1                     Auditoria
│   └── Report.ps1                    Consolidação de relatórios
│
└── docs/                             Documentação
    ├── INSTALACAO.md                 Guia de Instalação
    ├── CONFIGURACAO.md               Guia de Configuração
    ├── UTILIZACAO.md                 Guia de Utilização
    ├── MANUAL-DO-USUARIO.md          Manual do Usuário
    ├── MANUAL-DO-ADMINISTRADOR.md    Manual do Administrador
    ├── MANUAL-TECNICO.md             Manual Técnico
    ├── MENUS.md                      Descrição dos menus
    ├── FUNCIONALIDADES.md            Descrição das funcionalidades
    ├── ARQUITETURA.md                Arquitetura da aplicação
    ├── ESTRUTURA.md                  Este documento
    ├── REQUISITOS.md                 Requisitos do sistema
    ├── COMPATIBILIDADE.md            Compatibilidade
    ├── LIMITACOES.md                 Limitações conhecidas
    ├── BOAS-PRATICAS.md              Boas práticas
    ├── FAQ.md                        Perguntas frequentes
    ├── SOLUCAO-DE-PROBLEMAS.md       Solução de problemas
    ├── ATUALIZACAO.md                Política de atualização
    └── CREDITOS.md                   Créditos
```

---

## O que é cada arquivo

### `Launcher.bat`

O programa. Contém a interface, os menus, a autoelevação, a detecção de ambiente, o
controle de fluxo, o motor de log e as rotinas Batch de contingência.

É o único arquivo que o usuário executa.

### `remote.ps1`

Inicializador opcional para execução remota. Baixa a versão estável mais recente,
valida a integridade e entrega o controle ao `Launcher.bat`. Não participa da
execução local e pode ser removido sem afetar o funcionamento do projeto.

### `Modules/Core.ps1`

Biblioteca central carregada por todos os demais módulos. Concentra:

- inicialização de contexto e escolha do diretório de gravação;
- registro estruturado de log;
- tratamento e classificação de erros;
- testes de ambiente (administrador, versão do Windows, TPM, Secure Boot, BitLocker,
  conectividade, WMI e CIM);
- acumulação de constatações e seções;
- geração dos relatórios em TXT, CSV, JSON e HTML;
- utilitários de arquivo, registro e serviço, com proteções contra remoção de
  caminhos críticos.

### `Modules/Collectors.ps1`

Funções de **coleta somente leitura**. Nenhuma delas altera o sistema. Existe para
que `Audit.ps1`, `Report.ps1` e os módulos de domínio compartilhem a mesma fonte de
dados, sem duplicar consultas.

### Módulos de domínio

Os outros vinte arquivos. Cada um cobre uma área e expõe um conjunto fixo de
ações. Todos seguem o mesmo esqueleto — veja o [Manual Técnico](MANUAL-TECNICO.md).

---

## Arquivos gerados em tempo de execução

Nenhum deles faz parte do projeto; todos são criados durante o uso.

| Arquivo | Onde | Conteúdo |
|---|---|---|
| `Relatorio_Manutencao.txt` | Pasta do programa ou Área de Trabalho | Log acumulado de todas as execuções |
| `COMPARTDISK_Relatorios/<sessão>/` | Ao lado do arquivo acima | Relatórios da sessão nos quatro formatos |
| `COMPARTDISK_Bootstrap.log` | Pasta temporária | Trace de inicialização |
| `Firewall_Backup.wfw` | Pasta de log | Backup das regras, antes de resetar o firewall |
| `Relatorio_Bateria.html` | Pasta de log | Relatório de bateria do Windows |

Todos estão listados no `.gitignore` e não devem ser versionados.

---

## Convenções do código-fonte

| Convenção | Motivo |
|---|---|
| Arquivos em ASCII puro, sem acentuação | Elimina conflitos entre a página de código do console, o PowerShell 5.1 (que lê arquivos sem marca de ordem de bytes como ANSI) e o PowerShell 7 (que assume UTF-8) |
| `.ps1` com marca de ordem de bytes UTF-8 | Garante leitura correta pelos dois motores |
| `.bat` **sem** marca de ordem de bytes | O interpretador de comandos falharia na primeira linha |
| Fim de linha CRLF | Padrão do Windows |
| Documentação em UTF-8, com acentuação | É lida por pessoas, não pelo console |

---

[Voltar ao índice](../README.md) · Próximo: [Arquitetura](ARQUITETURA.md)
