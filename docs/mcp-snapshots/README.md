# MCP catalog snapshots

Each file is an export of the live Higgsfield MCP server (`https://mcp.higgsfield.ai/mcp`), in the shape the app's Debug › Export MCP Tool Catalog… writes (`HiggsfieldAccount.exportCatalog`):

```
{exportedAt, protocolVersion, tools: [tools/list entries], models: {list: {video, image, audio}, get: {model_id: answer}}}
```

A Debug build can also write it to standard output without the save panel: launched with `JUTSU_DEBUG_EXPORT_CATALOG=1` (`DebugLaunchHooks`), it waits up to a minute for the signed-in account, prints the export and quits (exit status 1 with the error on standard error). For example, with `JUTSU_DEBUG_START_HIDDEN=1` so no window opens:

```
open -g -n --env JUTSU_DEBUG_EXPORT_CATALOG=1 --env JUTSU_DEBUG_START_HIDDEN=1 --stdout <file> <Debug app>
```

Only free, read-only calls go into a snapshot: `tools/list`, then `models_explore` `list` per type (every page, `limit` 100) and `get` for every listed video and image model. The access token, session ID, account email and user ID are never stored. Per-account fields such as the `unlim` block are kept, because #22 needs them.

`live-2026-10-15/` holds live answers of calls the catalog export doesn't make, one file per call as `{tool, arguments, answer}` (`answer` is the call's `structuredContent`; an `isError` answer adds `"isError": true` and the first line of its `text`). Most are free, read-only calls with only public catalog URLs. The paid run of issue #114 added `generate_video_count_2`, `generate_image_count_2`, `generate_image_use_unlim_refused`, `jobs_wait_running`, `jobs_wait_completed` and `media_import_url`: trimmed to the keys the app reads, every result and media URL replaced by `https://example.com/<file name>`, no request IDs. Tests replay them through `CatalogSnapshot.liveAnswer`.

`docs/higgsfield-api.md` is checked against the newest snapshot. The `AccountModel.…Confirmed` switches that wait on a confirmed tool schema are listed in issue #37.
