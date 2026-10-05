# CleanerCRTV

App nativo macOS (SwiftUI + Liquid Glass) de limpeza e espaço em disco, no espírito do CleanMyMac X
e do OmniDiskSweeper. Família CRTV (DownloaderCRTV, SplitterCRTV).

## Módulos
- **Painel** — escaneamento inteligente que junta tudo.
- **Lixo do sistema** — caches, registros, restos de desenvolvimento, downloads esquecidos.
- **Grandes e antigos** / **Duplicados** — arquivos enormes, esquecidos e cópias idênticas.
- **Mapa do disco** — árvore por tamanho (OmniDiskSweeper) + gráfico em raios de sol.
- **Desinstalador** — app + preferências, caches, contêineres e restos.
- **Otimização** — itens de início, agentes em segundo plano, manutenção.
- **Monitor** — CPU, memória, disco e rede, também na barra de menus.
- **Histórico** — tudo o que foi removido.

## Segurança
- Toda remoção passa por `Remover` (CleanerCore) → `SafetyGuard` → confirmação na `RemovalSheet`.
- Lixeira por padrão; permanente só marcando "Entendo…". Só pasta pessoal, /Applications, /Users/Shared e volumes externos.
- Pastas ignoradas em Ajustes ▸ Ignorar valem para todas as varreduras.

## Build
```bash
swift test                    # regras de segurança e varreduras (CleanerCore)
scripts/build-app.sh          # build/CleanerCRTV.app (--install copia para /Applications)
scripts/make-dmg.sh           # build/CleanerCRTV-<versão>.dmg
```
Assinatura ad-hoc: o Acesso Total ao Disco fica preso à assinatura, então cada build novo pode pedir para
reconceder em Ajustes.

## Pastas
- Histórico: `~/Library/Application Support/CleanerCRTV/history.json`
