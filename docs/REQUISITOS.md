# Requisitos do Sistema

**COMPARTDISK 1.3.0** · Desenvolvido por Edsilas

---

## Requisitos mínimos

| Item | Exigência |
|---|---|
| Sistema operacional | Windows — compatível atualmente com Windows 10 e Windows 11 |
| Edição | Home, Pro, Education ou Enterprise |
| Arquitetura | 64 bits (x64 ou ARM64) |
| Permissão | Conta com privilégio de administrador |
| Espaço em disco | 2 MB para o programa, mais espaço para os relatórios |
| Software adicional | **Nenhum** |

## O que **não** é necessário

- Instalador ou pacote de redistribuição
- .NET Framework em versão específica
- Módulos do PowerShell Gallery
- Conexão com a internet (exceto para atualizar programas)
- Ferramentas de terceiros

A ferramenta usa exclusivamente componentes que já acompanham o Windows.

---

## Componentes opcionais

Nenhum destes é obrigatório. A ausência de qualquer um deles apenas reduz a
profundidade do diagnóstico — **nenhuma funcionalidade deixa de existir**.

| Componente | Se estiver presente | Se estiver ausente |
|---|---|---|
| **PowerShell 5.1** | Diagnóstico completo e relatórios nos quatro formatos | Rotinas Batch equivalentes assumem |
| **PowerShell 7** | Mesmo que acima, com melhor desempenho | PowerShell 5.1 é usado |
| **Winget** | Atualização de programas instalados | Opção informa indisponibilidade |
| **WMIC** | Consultas de hardware no modo Batch | Consultas alternativas são usadas |
| **PnPUtil** | Backup e inventário de drivers | Opção informa indisponibilidade |
| **manage-bde** | Consulta ao BitLocker no modo Batch | Opção informa indisponibilidade |

> O WMIC foi marcado como obsoleto pela Microsoft e removido de instalações recentes
> do Windows 11. A ferramenta detecta isso e usa caminhos alternativos.

Para ver o que foi detectado na sua máquina, abra o menu `9`.

---

## Espaço em disco para os relatórios

| Tipo de relatório | Tamanho aproximado |
|---|---|
| Auditoria Rápida | 100 a 300 KB |
| Auditoria Completa | 500 KB a 3 MB |
| Backup de drivers | 200 MB a 2 GB |

O backup de drivers é o único que consome espaço significativo. A ferramenta verifica
o espaço livre antes de iniciá-lo.

---

## Permissões

A ferramenta solicita elevação automaticamente ao abrir. Sem privilégio
administrativo, o Windows recusaria:

- reparo de arquivos de sistema;
- alteração de configuração de rede;
- gerenciamento de serviços;
- leitura de informações de hardware e segurança;
- gerenciamento de contas locais.

Se a elevação for recusada, a ferramenta **continua funcionando em modo reduzido** e
avisa claramente na tela, em vez de fechar.

---

[Voltar ao índice](../README.md) · Próximo: [Compatibilidade](COMPATIBILIDADE.md)
