<#
.SYNOPSIS
  Build a self contained HTML index of documents and PDFs. Fast, read only,
  with favourites and labels saved in the browser.

.DESCRIPTION
  Walks a folder iteratively using a stack and .NET file enumerators.
  Survives access denied folders, long paths, and big trees without crashing.
  Writes one HTML file that has a live search box, type filter, favourites
  (star) and free text labels per file. Favourites and labels live in the
  browser's localStorage so they persist across rescans.

  The script only reads from the scanned folder. It never writes there.

.PARAMETER Root
  The folder to scan. Defaults to the current directory.

.PARAMETER Output
  Path to the HTML file to write. Defaults to your Desktop so nothing is
  written into the scanned tree.

.PARAMETER Extensions
  File extensions to include. Defaults to common doc and pdf types.

.PARAMETER IndexId
  Tag that namespaces favourites and labels in localStorage. Defaults to a
  hash of the root path so rescans of the same root reuse the same data.

.PARAMETER Verbose
  Show each skipped folder. Off by default to keep output clean.

.EXAMPLE
  .\Build-DocIndex.ps1 -Root "D:\SharedDocs"

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Build-DocIndex.ps1 -Root "\\server\share" -Output "C:\Users\me\Desktop\index.html"

.NOTES
  Requires PowerShell 5.1 or later. Read only on the scanned folder.
  If a folder is denied, the script skips it and continues.
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

# Do NOT use 'Stop'. We want non terminating errors to be ignored so we can
# survive access denied folders. We use try/catch only where we deliberately
# want to handle a failure.
$ErrorActionPreference = 'Continue'

# ---------- Validate root ----------

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host "ERROR: Root folder not found: $Root" -ForegroundColor Red
    exit 1
}

try {
    $rootFull = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
} catch {
    Write-Host "ERROR: Could not resolve path '$Root'. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------- Decide output path ----------

if (-not $Output) {
    # Desktop is more reliable than Documents (which is often redirected)
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) {
        $desktop = $env:USERPROFILE
    }
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) {
        $desktop = (Get-Location).Path
    }

    # Make a short safe name from the root
    $rootLeaf = Split-Path -Leaf $rootFull
    if (-not $rootLeaf) {
        $rootLeaf = ($rootFull -replace '[\\:/]', '_').Trim('_')
    }
    if (-not $rootLeaf) { $rootLeaf = 'root' }

    $Output = Join-Path $desktop ("doc-index_" + $rootLeaf + ".html")
}

# Ensure output folder exists
$outputDir = Split-Path -Parent $Output
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    try {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    } catch {
        Write-Host "ERROR: Could not create output directory '$outputDir'. $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ---------- Compute index id ----------

if (-not $IndexId) {
    try {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($rootFull.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        $IndexId = ([System.BitConverter]::ToString($hash) -replace '-','').Substring(0,12).ToLowerInvariant()
        $sha.Dispose()
    } catch {
        # Fallback if crypto unavailable
        $IndexId = ([Math]::Abs($rootFull.ToLowerInvariant().GetHashCode())).ToString('x')
    }
}

# ---------- Prepare ----------

Write-Host ("Scanning: {0}" -f $rootFull) -ForegroundColor Cyan
Write-Host "This is read only. Nothing in the scanned folder will be changed."
Write-Host ("Output will be written to: {0}" -f $Output)
Write-Host ""

$start = Get-Date

# Build extension hash set (case insensitive)
$extSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($e in $Extensions) {
    $key = $e.Trim()
    if (-not $key) { continue }
    if (-not $key.StartsWith('.')) { $key = '.' + $key }
    [void]$extSet.Add($key)
}

$records = New-Object 'System.Collections.Generic.List[object]'
$rootForRel = $rootFull
if (-not $rootForRel.EndsWith('\') -and -not $rootForRel.EndsWith('/')) {
    $rootForRel = $rootForRel + '\'
}

# ---------- Iterative walker ----------
# Use a Stack of paths. No recursion, no call depth limits.
# Each folder is enumerated inside its own try/catch so one bad folder
# does not stop the whole scan.

$stack = New-Object 'System.Collections.Generic.Stack[string]'
$stack.Push($rootFull)

$dirCount = 0
$matched = 0
$skippedFolders = 0
$skippedFiles = 0
$lastReport = Get-Date

while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    $dirCount++

    # Enumerate files in this folder
    $fileEnum = $null
    try {
        $fileEnum = [System.IO.Directory]::EnumerateFiles($current)
    } catch {
        $skippedFolders++
        Write-Verbose ("Skipped (files): {0} - {1}" -f $current, $_.Exception.Message)
        $fileEnum = $null
    }

    if ($fileEnum) {
        # Use a manual enumerator so we can advance past errors
        $iter = $null
        try { $iter = $fileEnum.GetEnumerator() } catch { $iter = $null }

        if ($iter) {
            while ($true) {
                $hasNext = $false
                try {
                    $hasNext = $iter.MoveNext()
                } catch {
                    $skippedFiles++
                    Write-Verbose ("Skipped a file in {0} - {1}" -f $current, $_.Exception.Message)
                    # Try to keep going
                    continue
                }
                if (-not $hasNext) { break }

                $file = $iter.Current
                try {
                    $ext = [System.IO.Path]::GetExtension($file)
                    if (-not $extSet.Contains($ext)) { continue }

                    $info = New-Object System.IO.FileInfo $file

                    # Build relative folder
                    $rel = $file
                    if ($rel.Length -ge $rootForRel.Length -and
                        $rel.Substring(0, $rootForRel.Length).Equals($rootForRel, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rel = $rel.Substring($rootForRel.Length)
                    }
                    $folder = [System.IO.Path]::GetDirectoryName($rel)
                    if ([string]::IsNullOrEmpty($folder)) { $folder = '.' }

                    $records.Add([pscustomobject]@{
                        n = $info.Name
                        f = $folder
                        e = $ext.ToLowerInvariant().TrimStart('.')
                        s = [int64]$info.Length
                        m = $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                        p = $info.FullName
                    })
                    $matched++

                    # Progress every 2 seconds
                    $now = Get-Date
                    if (($now - $lastReport).TotalSeconds -ge 2) {
                        Write-Host ("  ... {0} matched, {1} folders scanned, {2} skipped" -f $matched, $dirCount, ($skippedFolders + $skippedFiles))
                        $lastReport = $now
                    }
                } catch {
                    $skippedFiles++
                }
            }

            try { $iter.Dispose() } catch { }
        }
    }

    # Enumerate subfolders and push onto stack
    $dirEnum = $null
    try {
        $dirEnum = [System.IO.Directory]::EnumerateDirectories($current)
    } catch {
        $skippedFolders++
        Write-Verbose ("Skipped (dirs): {0} - {1}" -f $current, $_.Exception.Message)
        $dirEnum = $null
    }

    if ($dirEnum) {
        $diter = $null
        try { $diter = $dirEnum.GetEnumerator() } catch { $diter = $null }
        if ($diter) {
            while ($true) {
                $hasNext = $false
                try { $hasNext = $diter.MoveNext() }
                catch {
                    $skippedFolders++
                    continue
                }
                if (-not $hasNext) { break }
                try { $stack.Push($diter.Current) } catch { $skippedFolders++ }
            }
            try { $diter.Dispose() } catch { }
        }
    }
}

$elapsed = (Get-Date) - $start
Write-Host ""
Write-Host ("Scan complete:")
Write-Host ("  Folders scanned: {0}" -f $dirCount)
Write-Host ("  Files matched:   {0}" -f $matched)
Write-Host ("  Folders skipped: {0}" -f $skippedFolders)
Write-Host ("  Files skipped:   {0}" -f $skippedFiles)
Write-Host ("  Time elapsed:    {0:n1} seconds" -f $elapsed.TotalSeconds)
Write-Host ""

if ($matched -eq 0) {
    Write-Host "WARNING: No files matched. The HTML will be empty." -ForegroundColor Yellow
    Write-Host "Check your extension list and that the root contains matching files."
}

# ---------- Build JSON ----------
# Manual StringBuilder for speed and to avoid ConvertTo-Json overhead.

Write-Host "Building HTML..."

function Escape-JsonString {
    param([string] $s)
    if ($null -eq $s) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        switch ($code) {
            8  { [void]$sb.Append('\b'); continue }
            9  { [void]$sb.Append('\t'); continue }
            10 { [void]$sb.Append('\n'); continue }
            12 { [void]$sb.Append('\f'); continue }
            13 { [void]$sb.Append('\r'); continue }
            34 { [void]$sb.Append('\"'); continue }
            92 { [void]$sb.Append('\\'); continue }
            60 { [void]$sb.Append('\u003c'); continue }  # < so </script> cannot break HTML
            62 { [void]$sb.Append('\u003e'); continue }  # >
            38 { [void]$sb.Append('\u0026'); continue }  # &
            default {
                if ($code -lt 32) {
                    [void]$sb.AppendFormat('\u{0:x4}', $code)
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

$jsonBuilder = New-Object System.Text.StringBuilder
[void]$jsonBuilder.Append('[')
$first = $true
foreach ($r in $records) {
    if (-not $first) { [void]$jsonBuilder.Append(',') } else { $first = $false }
    [void]$jsonBuilder.Append('{"n":')
    [void]$jsonBuilder.Append((Escape-JsonString $r.n))
    [void]$jsonBuilder.Append(',"f":')
    [void]$jsonBuilder.Append((Escape-JsonString $r.f))
    [void]$jsonBuilder.Append(',"e":')
    [void]$jsonBuilder.Append((Escape-JsonString $r.e))
    [void]$jsonBuilder.Append(',"s":')
    [void]$jsonBuilder.Append($r.s.ToString())
    [void]$jsonBuilder.Append(',"m":')
    [void]$jsonBuilder.Append((Escape-JsonString $r.m))
    [void]$jsonBuilder.Append(',"p":')
    [void]$jsonBuilder.Append((Escape-JsonString $r.p))
    [void]$jsonBuilder.Append('}')
}
[void]$jsonBuilder.Append(']')
$json = $jsonBuilder.ToString()

# ---------- HTML template ----------

$html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Document index</title>
<style>
  :root {
    --bg: #fafafa; --fg: #222; --muted: #777; --border: #ddd;
    --row-hover: #eef5ff; --accent: #1a66cc; --star: #f5b301;
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
const DATA = __JSON_PLACEHOLDER__;
const INDEX_ID = '__INDEXID_PLACEHOLDER__';
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
  const idx = Math.max(p.lastIndexOf('\\'), p.lastIndexOf('/'));
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
    const path = escapeHtml(r.p);
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

# ---------- Substitute placeholders ----------
# Using non-curly placeholders to avoid any chance of collision with content.

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$rootEscaped = $rootFull -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'

$html = $html.Replace('__JSON_PLACEHOLDER__', $json)
$html = $html.Replace('__INDEXID_PLACEHOLDER__', $IndexId)
$html = $html.Replace('{{ROOT}}', $rootEscaped)
$html = $html.Replace('{{COUNT}}', $matched.ToString())
$html = $html.Replace('{{GENERATED}}', $generated)

# ---------- Write file ----------

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Output, $html, $utf8NoBom)
} catch {
    Write-Host ("ERROR: Could not write output file '{0}'. {1}" -f $Output, $_.Exception.Message) -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host ("Done. Wrote {0}" -f $Output) -ForegroundColor Green
Write-Host ("Index id: {0}" -f $IndexId)
Write-Host "Double click the HTML file to open it in your browser."
