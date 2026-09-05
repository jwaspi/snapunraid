<?php
// sync_plg.php - regenerate <FILE><INLINE> blocks in snapunraid.plg from the
// source tree, so the .plg stays self-contained (Unraid extracts each FILE to
// its absolute path on install). Skips FILE blocks whose target doesn't exist
// in source (e.g. uninstall.sh, which is only extracted on remove).
//
// Usage: php build/sync_plg.php [plg] [source-base]
//   plg          .plg to update (default: ../snapunraid.plg)
//   source-base  directory the FILE paths are relative to (default: ../source)
$plg = $argv[1] ?? __DIR__ . '/../snapunraid.plg';
$base = rtrim($argv[2] ?? __DIR__ . '/../source', '/') . '/';

$content = file_get_contents($plg);
if ($content === false) { fwrite(STDERR, "cannot read $plg\n"); exit(1); }

$pattern = '/(<FILE Name="([^"]+)"[^>]*>\s*<INLINE>\s*<!\[CDATA\[)(.*?)(\]\]>\s*<\/INLINE>\s*<\/FILE>)/s';
$count = 0;
$content = preg_replace_callback($pattern, function ($m) use (&$count, $base) {
    $path = $base . ltrim($m[2], '/');
    if (!file_exists($path)) {
        return $m[0]; // leave untouched (e.g. uninstall.sh)
    }
    $live = file_get_contents($path);
    if ($live === false) {
        return $m[0];
    }
    if (strpos($live, ']]>') !== false) {
        fwrite(STDERR, "WARNING: $path contains ']]>' - skipping to avoid corrupting CDATA\n");
        return $m[0];
    }
    $count++;
    return $m[1] . $live . $m[4];
}, $content);

if ($content === null) { fwrite(STDERR, "regex error\n"); exit(1); }
file_put_contents($plg, $content);
echo "regenerated $count FILE block(s)\n";
