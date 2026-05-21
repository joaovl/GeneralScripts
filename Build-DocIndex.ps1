<#
.SYNOPSIS
  Build a single self contained HTML index of documents and PDFs.
  Fast, read only, with favourites and labels saved in the browser.

.DESCRIPTION
  Walks a root folder recursively using .NET EnumerateFiles for speed,
  collects metadata for files matching the given extensions, and writes one
  HTML file with all data embedded as JSON. The HTML has a search box,
  type filter, favourites (star) and free text labels per file. Favourites
  and labels are kept in the browser's localStorage so they survive
  rescans. The script never writes anything inside the scanned folder.

.PARAMETER Root
  The folder to scan. Defaults to the current directory.

.PARAMETER Output
  Path to the HTML file to write. Defaults to your Documents folder so
  nothing is written into the scanned tree.

.PARAMETER Extensions
  File extensions to include. Defaults to common doc and pdf types.

.PARAMETER IndexId
  Tag that namespaces favourites and labels in localStorage. Defaults to a
  hash of the root path so rescans of the same root keep the same data.

.EXAMPLE
  .\Build-DocIndex.ps1 -Root "D:\SharedDocs"

.EXAMPLE
  .\Build-DocIndex.ps1 -Root "\\fileserver\projects" -Output "C:\Users\me\projects.html"

.NOTES
  Requires PowerShell 5.1 or later. Read only on the scanned folder.
#>

[CmdletBinding()]
param(
    [string] $Root = (Get-Location).Path,
    [string] $Output,
    [string[]] $Extensions = @(
        '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
        '.txt', '.md', '.rtf', '.csv', '.odt', '.ods', '.odp'
    ),
    [string] $IndexId
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Root)) {
    throw "Root folder not found: $Root"
}

$rootFull = (Resolve-Path -LiteralPath $Root).Path

if (-not $Output) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $safeName = ($rootFull -replace '[\\:/]', '_').Trim('_')
    $Output = Join-Path $docs ("doc-index_" + $safeName + ".html")
}

if (-not $IndexId) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($rootFull.ToLowerInvariant())
    $hash = $sha.ComputeHash($bytes)
    $IndexId = ([System.BitConverter]::ToString($hash) -replace '-','').Substring(0,12).ToLowerInvariant()
}

Write-Host ("Scanning {0}" -f $rootFull)
Write-Host "This is read only. Nothing in the scanned folder is changed."
$start = Get-Date

$extSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($e in $Extensions) {
    $key = $e
    if (-not $key.StartsWith('.')) { $key = '.' + $key }
    [void]$extSet.Add($key)
}

$records = New-Object 'System.Collections.Generic.List[object]'
$rootForRel = $rootFull.TrimEnd('\') + '\'

$script:dirCount = 0
$script:matched = 0
$script:skipped = 0
$script:lastReport = Get-Date
$script:records = $records
$script:extSet = $extSet
$script:rootForRel = $rootForRel

function Walk-Folder {
    param([string] $Path)
    $script:dirCount++
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($Path)) {
            try {
                $ext = [System.IO.Path]::GetExtension($file)
                if (-not $script:extSet.Contains($ext)) { continue }
                $info = New-Object System.IO.FileInfo $file

                $rel = $file
                if ($rel.StartsWith($script:rootForRel, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $rel.Substring($script:rootForRel.Length)
                }
                $folder = [System.IO.Path]::GetDirectoryName($rel)
                if (-not $folder) { $folder = '.' }

                $script:records.Add([pscustomobject]@{
                    n = $info.Name
                    f = $folder
                    e = $ext.ToLowerInvariant().TrimStart('.')
                    s = [int64]$info.Length
                    m = $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    p = $info.FullName
                })
                $script:matched++

                $now = Get-Date
                if (($now - $script:lastReport).TotalSeconds -ge 2) {
                    Write-Host ("  ... {0} matched, {1} folders scanned" -f $script:matched, $script:dirCount)
                    $script:lastReport = $now
                }
            } catch {
                $script:skipped++
            }
        }
        foreach ($sub in [System.IO.Directory]::EnumerateDirectories($Path)) {
            Walk-Folder -Path $sub
        }
    } catch [System.UnauthorizedAccessException] {
        $script:skipped++
    } catch [System.IO.PathTooLongException] {
        $script:skipped++
    } catch {
        $script:skipped++
    }
}

Walk-Folder -Path $rootFull

$elapsed = (Get-Date) - $start
Write-Host ("Scanned {0} folders, matched {1} files, skipped {2}, took {3:n1}s" -f `
    $script:dirCount, $script:matched, $script:skipped, $elapsed.TotalSeconds)

$json = $records | ConvertTo-Json -Depth 4 -Compress
if (-not $json) { $json = '[]' }
if (-not $json.StartsWith('[')) { $json = '[' + $json + ']' }

$html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Document index</title>
<style>
  :root {
    --bg: #fafafa;
    --fg: #222;
    --muted: #777;
    --border: #ddd;
    --row-hover: #eef5ff;
    --accent: #1a66cc;
    --star: #f5b301;
  }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif; background: var(--bg); color: var(--fg); font-size: 14px; }
  header { position: sticky; top: 0; background: white; border-bottom: 1px solid var(--border); padding: 12px 20px; z-index: 10; }
  header h1 { margin: 0 0 8px 0; font-size: 18px; font-weight: 600; }
  .meta { color: var(--muted); font-size: 12px; margin-bottom: 8px; word-break: break-all; }
  .controls { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  input[type="search"], input[type="text"], select { padding: 8px 10px; border: 1px solid var(--border); border-radius: 4px; font-size: 14px; background: white; }
  input[type="search"] { flex: 1; min-width: 240px; }
  .count { color: var(--muted); font-size: 12px; }
  .toggle { padding: 8px 12px; border: 1px solid var(--border); border-radius: 4px; background: white; cursor: pointer; font-size: 14px; }
  .toggle.active { background: #fff3cd; border-color: var(--star); }
  table { width: 100%; border-collapse: collapse; background: white; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
  th { background: #f3f3f3; font-weight: 600; cursor: pointer; user-select: none; }
  th .arrow { color: var(--muted); font-size: 10px; margin-left: 4px; }
  tbody tr:hover { background: var(--row-hover); }
  td.star { width: 28px; text-align: center; cursor: pointer; font-size: 18px; color: #ccc; user-select: none; }
  td.star.on { color: var(--star); }
  td.name a { color: var(--accent); text-decoration: none; word-break: break-all; }
  td.name a:hover { text-decoration: underline; }
  td.folder { color: var(--muted); word-break: break-all; }
  .folder-link { color: var(--muted); margin-left: 6px; text-decoration: none; font-size: 11px; }
  .folder-link:hover { color: var(--accent); text-decoration: underline; }
  td.ext { text-transform: uppercase; font-size: 11px; color: white; background: #888; padding: 2px 6px; border-radius: 3px; display: inline-block; }
  td.ext.pdf { background: #c0392b; }
  td.ext.doc, td.ext.docx { background: #2c5aa0; }
  td.ext.xls, td.ext.xlsx, td.ext.csv { background: #217346; }
  td.ext.ppt, td.ext.pptx { background: #d24726; }
  td.ext.txt, td.ext.md { background: #555; }
  td.size, td.modified { white-space: nowrap; color: #555; font-variant-numeric: tabular-nums; }
  td.label input { width: 100%; min-width: 100px; border: 1px solid transparent; background: transparent; padding: 4px 6px; border-radius: 3px; font-size: 13px; }
  td.label input:hover { border-color: var(--border); background: white; }
  td.label input:focus { border-color: var(--accent); background: white; outline: none; }
  .empty { padding: 40px; text-align: center; color: var(--muted); }
  mark { background: #fff3a3; color: inherit; padding: 0; }
  .export-bar { padding: 8px 20px; background: #f3f3f3; border-bottom: 1px solid var(--border); font-size: 12px; color: var(--muted); }
  .export-bar button { margin-left: 8px; padding: 4px 8px; font-size: 12px; cursor: pointer; }
</style>
</head>
<body>
<header>
  <h1>Document index</h1>
  <div class="meta">Root: <code>{{ROOT}}</code> &middot; Generated {{GENERATED}} &middot; {{COUNT}} files</div>
  <div class="controls">
    <input id="q" type="search" placeholder="Search name, folder, label, or type..." autofocus>
    <select id="extFilter"><option value="">All types</option></select>
    <button id="favBtn" class="toggle" title="Show only starred files">&#9733; Favourites only</button>
    <input id="labelFilter" type="text" placeholder="Filter by label..." style="width: 160px;">
    <span class="count" id="count"></span>
  </div>
</header>
<div class="export-bar">
  Favourites and labels are saved in this browser only.
  <button onclick="exportData()">Export</button>
  <button onclick="document.getElementById('importFile').click()">Import</button>
  <input type="file" id="importFile" accept=".json" style="display:none" onchange="importData(event)">
  <button onclick="clearData()">Clear all</button>
</div>
<table>
  <thead>
    <tr>
      <th style="width:28px"></th>
      <th data-sort="n">Name <span class="arrow"></span></th>
      <th data-sort="e">Type <span class="arrow"></span></th>
      <th data-sort="f">Folder <span class="arrow"></span></th>
      <th data-sort="s">Size <span class="arrow"></span></th>
      <th data-sort="m">Modified <span class="arrow"></span></th>
      <th>Label</th>
    </tr>
  </thead>
  <tbody id="rows"></tbody>
</table>
<div id="empty" class="empty" style="display:none">No files match.</div>
<script>
const DATA = {{JSON}};
const INDEX_ID = '{{INDEX_ID}}';
const STORE_KEY = 'docindex_' + INDEX_ID;

let store = { fav: {}, lbl: {} };
try {
  const raw = localStorage.getItem(STORE_KEY);
  if (raw) store = JSON.parse(raw);
} catch (e) { console.warn('Could not load saved data', e); }

function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(store)); }
  catch (e) { alert('Could not save. Browser storage may be full.'); }
}

const q = document.getElementById('q');
const extFilter = document.getElementById('extFilter');
const favBtn = document.getElementById('favBtn');
const labelFilter = document.getElementById('labelFilter');
const rowsEl = document.getElementById('rows');
const countEl = document.getElementById('count');
const emptyEl = document.getElementById('empty');

let sortKey = 'n';
let sortDir = 1;
let favOnly = false;

const exts = [...new Set(DATA.map(r => r.e))].sort();
for (const e of exts) {
  const opt = document.createElement('option');
  opt.value = e;
  opt.textContent = e.toUpperCase();
  extFilter.appendChild(opt);
}

function fmtSize(b) {
  if (b < 1024) return b + ' B';
  if (b < 1024*1024) return (b/1024).toFixed(1) + ' KB';
  if (b < 1024*1024*1024) return (b/1024/1024).toFixed(1) + ' MB';
  return (b/1024/1024/1024).toFixed(2) + ' GB';
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function highlight(text, term) {
  const safe = escapeHtml(text);
  if (!term) return safe;
  const re = new RegExp('(' + term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
  return safe.replace(re, '<mark>$1</mark>');
}

function fileUrl(p) {
  let s = p.replace(/\\/g, '/');
  return 'file:///' + encodeURI(s).replace(/#/g, '%23').replace(/\?/g, '%3F');
}

function folderUrl(p) {
  const idx = p.lastIndexOf('\\');
  const folder = idx >= 0 ? p.substring(0, idx) : p;
  return fileUrl(folder);
}

function render() {
  const term = q.value.trim().toLowerCase();
  const ext = extFilter.value;
  const labelTerm = labelFilter.value.trim().toLowerCase();
  let list = DATA;

  if (ext) list = list.filter(r => r.e === ext);
  if (favOnly) list = list.filter(r => store.fav[r.p]);
  if (labelTerm) {
    list = list.filter(r => {
      const l = (store.lbl[r.p] || '').toLowerCase();
      return l.includes(labelTerm);
    });
  }
  if (term) {
    const parts = term.split(/\s+/).filter(Boolean);
    list = list.filter(r => {
      const label = (store.lbl[r.p] || '').toLowerCase();
      const hay = (r.n + ' ' + r.f + ' ' + r.e + ' ' + label).toLowerCase();
      return parts.every(p => hay.includes(p));
    });
  }

  list = list.slice().sort((a, b) => {
    let av = a[sortKey], bv = b[sortKey];
    if (typeof av === 'string') av = av.toLowerCase();
    if (typeof bv === 'string') bv = bv.toLowerCase();
    if (av < bv) return -1 * sortDir;
    if (av > bv) return  1 * sortDir;
    return 0;
  });

  countEl.textContent = list.length + ' of ' + DATA.length + ' shown';
  emptyEl.style.display = list.length ? 'none' : 'block';

  const max = 2000;
  const shown = list.slice(0, max);
  const rows = shown.map(r => {
    const url = fileUrl(r.p);
    const furl = folderUrl(r.p);
    const isFav = !!store.fav[r.p];
    const label = store.lbl[r.p] || '';
    const labelEsc = escapeHtml(label).replace(/"/g, '&quot;');
    const path = r.p.replace(/"/g, '&quot;');
    return '<tr data-path="' + path + '">' +
      '<td class="star ' + (isFav ? 'on' : '') + '" title="Toggle favourite">&#9733;</td>' +
      '<td class="name"><a href="' + url + '">' + highlight(r.n, term) + '</a></td>' +
      '<td><span class="ext ' + r.e + '">' + r.e + '</span></td>' +
      '<td class="folder">' + highlight(r.f, term) +
        ' <a class="folder-link" href="' + furl + '" title="Open containing folder">[open folder]</a></td>' +
      '<td class="size">' + fmtSize(r.s) + '</td>' +
      '<td class="modified">' + r.m + '</td>' +
      '<td class="label"><input type="text" value="' + labelEsc + '" placeholder="Add label..."></td>' +
    '</tr>';
  }).join('');
  rowsEl.innerHTML = rows;

  if (list.length > max) {
    countEl.textContent += ' (showing first ' + max + ', refine search to see more)';
  }
}

rowsEl.addEventListener('click', (ev) => {
  const star = ev.target.closest('td.star');
  if (star) {
    const path = star.parentElement.dataset.path;
    if (store.fav[path]) { delete store.fav[path]; star.classList.remove('on'); }
    else { store.fav[path] = 1; star.classList.add('on'); }
    save();
  }
});

rowsEl.addEventListener('change', (ev) => {
  if (ev.target.tagName === 'INPUT' && ev.target.closest('td.label')) {
    const path = ev.target.closest('tr').dataset.path;
    const val = ev.target.value.trim();
    if (val) store.lbl[path] = val; else delete store.lbl[path];
    save();
  }
});

q.addEventListener('input', render);
extFilter.addEventListener('change', render);
labelFilter.addEventListener('input', render);
favBtn.addEventListener('click', () => {
  favOnly = !favOnly;
  favBtn.classList.toggle('active', favOnly);
  render();
});

document.querySelectorAll('th[data-sort]').forEach(th => {
  th.addEventListener('click', () => {
    const k = th.dataset.sort;
    if (sortKey === k) sortDir = -sortDir; else { sortKey = k; sortDir = 1; }
    document.querySelectorAll('th .arrow').forEach(a => a.textContent = '');
    th.querySelector('.arrow').textContent = sortDir === 1 ? '\u25B2' : '\u25BC';
    render();
  });
});

function exportData() {
  const blob = new Blob([JSON.stringify(store, null, 2)], {type: 'application/json'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'docindex-favs-labels-' + INDEX_ID + '.json';
  a.click();
}

function importData(ev) {
  const file = ev.target.files[0];
  if (!file) return;
  const r = new FileReader();
  r.onload = (e) => {
    try {
      const data = JSON.parse(e.target.result);
      if (data.fav) Object.assign(store.fav, data.fav);
      if (data.lbl) Object.assign(store.lbl, data.lbl);
      save();
      render();
      alert('Imported.');
    } catch (err) { alert('Bad file: ' + err.message); }
  };
  r.readAsText(file);
}

function clearData() {
  if (confirm('Remove all favourites and labels for this index?')) {
    store = { fav: {}, lbl: {} };
    save();
    render();
  }
}

render();
</script>
</body>
</html>
'@

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$rootEscaped = $rootFull -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'

$html = $html.Replace('{{JSON}}', $json)
$html = $html.Replace('{{ROOT}}', $rootEscaped)
$html = $html.Replace('{{COUNT}}', $records.Count.ToString())
$html = $html.Replace('{{GENERATED}}', $generated)
$html = $html.Replace('{{INDEX_ID}}', $IndexId)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Output, $html, $utf8NoBom)

Write-Host ""
Write-Host ("Done. Wrote {0}" -f $Output) -ForegroundColor Green
Write-Host ("Index id: {0} (favourites and labels are keyed by this)" -f $IndexId)
Write-Host "Double click the HTML to open in your browser."
