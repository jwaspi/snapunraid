<?php
// verify_plg.php - compare each <FILE><INLINE> block in snapunraid.plg
// against the source tree. Exit 1 on any mismatch.
//
// Usage: php build/verify_plg.php [plg] [source-base]
$plg = $argv[1] ?? __DIR__ . '/../snapunraid.plg';
$base = rtrim($argv[2] ?? __DIR__ . '/../source', '/') . '/';

$content = file_get_contents($plg);
if ($content === false) { fwrite(STDERR, "cannot read $plg\n"); exit(2); }

$pattern = '/(<FILE Name="([^"]+)"[^>]*>\s*<INLINE>\s*<!\[CDATA\[)(.*?)(\]\]>\s*<\/INLINE>\s*<\/FILE>)/s';
if (!preg_match_all($pattern, $content, $m, PREG_SET_ORDER)) {
    fwrite(STDERR, "no FILE blocks matched\n");
    exit(2);
}
$fail = 0;
$checked = 0;
foreach ($m as $b) {
    $path = $base . ltrim($b[2], '/');
    if (!file_exists($path)) {
        echo "SKIP (missing in source): $path\n";
        continue;
    }
    $live = file_get_contents($path);
    if ($live === false) { echo "ERROR reading $path\n"; $fail++; continue; }
    $checked++;
    if ($live === $b[3]) {
        echo "OK   $path\n";
    } else {
        echo "DIFF $path\n";
        $fail++;
    }
}
echo "\n$checked blocks checked, $fail mismatches\n";
exit($fail > 0 ? 1 : 0);
