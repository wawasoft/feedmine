# Preservação local — 2026-09-14

Estes artefatos existiam apenas no clone local do `feedmine`, removido durante a
limpeza do disco.

## `archive/mvp1-20260914` (branch)

Histórico completo dos 22 commits de `mvp1`/`mvp1-full-backup` (Share Extension,
deep link `feedmine://`, OPML import, FeedDiscoverySheet, PendingQueue,
RichShareFormatter). O push original foi recusado porque a árvore continha
`.build-device/SourcePackages/**/pack-*.pack` (225 MB, acima do limite de 100 MB
do GitHub); a branch foi reescrita removendo `.build-device`, `.build-dd`,
`.build-dd-device`, `.build-dd-fix`, `.build` e `.venv_feeds`.

## `feedmine-stash6.patch`

`stash@{6}` (WIP on mvp1): `feedmine.xcodeproj/project.pbxproj` (+8),
`project.yml` (+2). Não pôde ir como branch pelo mesmo motivo acima.

```bash
git apply feedmine-stash6.patch
```
