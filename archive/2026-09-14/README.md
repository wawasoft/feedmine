# Preservação local — 2026-09-14

Estes artefatos existiam apenas no clone local do `feedmine`, que foi removido
durante a limpeza do disco. Não cabiam em push direto porque o histórico da
branch `mvp1` contém `.build-device/SourcePackages/**/pack-*.pack` (225 MB),
recusado pelo limite de 100 MB do GitHub.

## `feedmine-mvp1-22-commits.patch`

Diff completo (base `a6d9501c` → `mvp1`, 22 commits) das branches `mvp1` e
`mvp1-full-backup`: Share Extension, deep link `feedmine://`, OPML import,
FeedDiscoverySheet, PendingQueue/PendingItemsMonitor, RichShareFormatter.

Excluídos do patch: `.build-device/`, `.build-dd/`, `.build-dd-device/`,
`.build-dd-fix/`, `.build/`, `.venv_feeds/` (artefatos de build, reconstruíveis).

Aplicar:

```bash
git apply feedmine-mvp1-22-commits.patch
```

## `feedmine-stash6.patch`

`stash@{6}` (WIP on mvp1): `feedmine.xcodeproj/project.pbxproj` (+8),
`project.yml` (+2).
