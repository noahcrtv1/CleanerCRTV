# CleanerCRTV

App nativo macOS (SwiftUI + Liquid Glass) de limpeza e espaço em disco, no espírito do CleanMyMac X
e do OmniDiskSweeper. Família CRTV (DownloaderCRTV, SplitterCRTV).

## Instalar no seu Mac

Precisa de um Mac com Apple Silicon (M1 ou mais novo) e macOS 26 ou mais novo.

1. Instale o **Xcode** pela App Store (grátis), abra uma vez e aceite a licença.
   Ele traz o compilador Swift e a ferramenta que gera o ícone.
2. Abra o app **Terminal** e rode:

```bash
git clone https://github.com/noahcrtv1/CleanerCRTV.git
cd CleanerCRTV
scripts/build-app.sh --install  # compila e instala em /Applications
```

O app aparece em **Aplicativos** como CleanerCRTV. Para varrer tudo, ele pede **Acesso Total ao Disco**
em Ajustes ▸ Privacidade e Segurança.

3. Na primeira vez que abrir, o macOS pode bloquear (o app não é assinado pela Apple).
   Vá em **Ajustes do Sistema ▸ Privacidade e Segurança** e clique em **Abrir Mesmo Assim**.

Para atualizar depois: `cd CleanerCRTV && git pull` e rode o último comando de novo.

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
